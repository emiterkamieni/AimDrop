// A single streaming HTTPS upload to the existing loopback receiver. One H3
// block is forwarded at a time; backend consent and cancellation flow upstream.
import Foundation
import Network

final class StreamingUpload: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    let length: Int?
    let requestHead: Data
    var onContinue: (() -> Void)?
    var onResponse: ((UInt32, Data, [String: String]) -> Void)?
    var onFailure: ((Error) -> Void)?
    private var timer: DispatchSourceTimer?
    private var finished = false
    private var accepted = false
    private var sent = 0
    private var buffer = Data()
    private var responseStatus: UInt32?
    private var responseHeaders: [String: String] = [:]
    private var responseLength = 0

    init(port: UInt16, headers: [String: String], queue: DispatchQueue) throws {
        self.queue = queue
        if let value = headers["content-length"] {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Int(value), parsed >= 0 else { throw ProbeError.stage("upload content length") }
            length = parsed
        } else { length = nil }

        var lines = ["POST /Upload HTTP/1.1", "Host: [::1]:\(port)",
                     "Connection: close", "Expect: 100-continue"]
        let excluded: Set<String> = ["host", "connection", "proxy-connection", "transfer-encoding",
                                     "content-length", "expect", "te", "trailer", "upgrade"]
        let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for (name, value) in headers where !excluded.contains(name.lowercased()) {
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }),
                  !value.utf8.contains(where: { $0 == 10 || $0 == 13 || $0 == 0 }) else {
                throw ProbeError.stage("invalid upload header")
            }
            lines.append("\(name): \(value)")
        }
        if let length { lines.append("Content-Length: \(length)") }
        else { lines.append("Transfer-Encoding: chunked") }
        requestHead = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)

        let tls = NWProtocolTLS.Options()
        // This connection is constructed only for the fixed IPv6 loopback host
        // and configured local receiver port, whose certificate is self-signed.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        connection = NWConnection(to: .hostPort(host: .ipv6(.loopback), port: NWEndpoint.Port(rawValue: port)!),
                                  using: NWParameters(tls: tls, tcp: tcp))
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.fail(ProbeError.stage("streaming backend timeout")) }
        timer.schedule(deadline: .now() + 10)
        timer.resume()
        self.timer = timer
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.finished else { return }
            switch state {
            case .ready:
                self.touch()
                self.receive()
                self.connection.send(content: self.requestHead, completion: .contentProcessed { error in
                    if let error { self.fail(error) }
                })
            case .failed(let error): self.fail(error)
            case .waiting(let error): self.fail(error)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    // Called only after 100 Continue. The caller waits for contentProcessed
    // before reading the next H3 block, bounding memory and TCP backlog.
    func send(_ data: Data, final: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        guard !finished, accepted else { completion(ProbeError.stage("upload stream closed")); return }
        guard data.count <= Int.max - sent else { fail(ProbeError.invalidArgument); return }
        sent += data.count
        if let length, sent > length || (final && sent != length) {
            fail(ProbeError.stage("truncated or oversized upload")); return
        }
        var wire = data
        if length == nil {
            wire = Data()
            if !data.isEmpty {
                wire.append(Data((String(data.count, radix: 16) + "\r\n").utf8))
                wire.append(data)
                wire.append(Data("\r\n".utf8))
            }
            if final { wire.append(Data("0\r\n\r\n".utf8)) }
        }
        touch()
        guard !wire.isEmpty else { completion(nil); return }
        connection.send(content: wire, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(error) }
            completion(error)
        })
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onContinue = nil
        onResponse = nil
        onFailure = nil
    }

    private func touch() { timer?.schedule(deadline: .now() + 30) }

    private func fail(_ error: Error) {
        guard !finished else { return }
        let callback = onFailure
        cancel()
        callback?(error)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            do {
                if let data { self.buffer.append(data); self.touch() }
                try self.parseResponse()
                if self.finished { return }
                if let error { throw error }
                guard !complete else { throw ProbeError.stage("backend closed upload before acknowledgment") }
                self.receive()
            } catch { self.fail(error) }
        }
    }

    private func parseResponse() throws {
        while responseStatus == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                guard buffer.count <= 65536 else { throw ProbeError.stage("backend headers too large") }
                return
            }
            guard end.lowerBound - buffer.startIndex <= 65536,
                  let text = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { throw ProbeError.stage("backend headers") }
            buffer.removeSubrange(..<end.upperBound)
            let lines = text.components(separatedBy: "\r\n")
            let statusLine = lines[0].split(separator: " ")
            guard statusLine.count >= 2, statusLine[0] == "HTTP/1.1",
                  let status = UInt32(statusLine[1]), (100...599).contains(status) else { throw ProbeError.stage("backend status") }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw ProbeError.stage("backend header syntax") }
                let name = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if name == "content-length", headers[name] != nil { throw ProbeError.stage("duplicate backend length") }
                headers[name] = value
            }
            if status < 200 {
                guard status != 101 else { throw ProbeError.stage("unexpected backend upgrade") }
                if status == 100 && !accepted {
                    accepted = true
                    let callback = onContinue
                    onContinue = nil
                    callback?()
                }
                continue
            }
            // ReceiverServer always replies with an explicit length, even for
            // errors. Reject unexpected framing instead of inventing an EOF.
            guard headers["transfer-encoding"] == nil, let value = headers["content-length"],
                  !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(value), length <= 8 * 1024 * 1024 else { throw ProbeError.stage("backend response length") }
            responseStatus = status
            responseLength = length
            responseHeaders = headers.filter { !["content-length", "connection", "transfer-encoding"].contains($0.key) }
        }
        guard buffer.count >= responseLength, let status = responseStatus else { return }
        guard buffer.count == responseLength else { throw ProbeError.stage("extra backend response data") }
        let callback = onResponse
        let data = buffer
        let headers = responseHeaders
        cancel()
        callback?(status, data, headers)
    }
}

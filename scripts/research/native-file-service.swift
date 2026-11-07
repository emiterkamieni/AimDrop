// HTTP3-to-loopback receiver bridge shared by the app helper and protocol checks.
import Foundation
import Network
import Distributed

final class ProbeContinuation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    @discardableResult func complete(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}

final class NativeFileService: @unchecked Sendable {
    let name = "pl.airfolder.files." + UUID().uuidString.lowercased()
    let pin = String(format: "%06d", Int.random(in: 0..<1_000_000))
    let queue = DispatchQueue(label: "pl.airfolder.fileprobe")
    var listener: NWListener?
    var browser: NWBrowser?
    var actorSystem: NWActorSystem?
    var peer: RPPairingDistributedActor?
    var connections: [NWConnection] = []
    var requests: [HTTP3BackendRequest] = []
    private var accepting = true
    private var drained: (() -> Void)?
    var identity: RPPairingTemporaryIdentity?
    let backend: LocalReceiverBackend
    let spoolDirectory: URL?
    init(port: UInt16? = nil, spoolDirectory: URL? = nil) {
        backend = LocalReceiverBackend(port: port)
        // Raw spool capture is an explicit test diagnostic. The app's backend
        // already owns durable receiving storage and completed files.
        self.spoolDirectory = spoolDirectory ?? ProcessInfo.processInfo.environment["AIRFOLDER_PROBE_SPOOL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    func updateIdentity(_ value: RPPairingTemporaryIdentity) async {
        await withCheckedContinuation { continuation in
            queue.async { self.identity = value; continuation.resume() }
        }
    }

    func start() async throws {
        guard let raw = AFCreateApplicationServiceHTTP3Parameters() else { throw ProbeError.stage("native QUIC parameters") }
        let listener = try NWListener(using: NWParameters(raw))
        self.listener = listener
        guard AFSetListenerPairingService(listener.nw, name, pin) else { throw ProbeError.stage("native pairing descriptor") }
        listener.newConnectionHandler = { connection in
            guard self.accepting else { connection.cancel(); return }
            self.connections.append(connection)
            print("native_http3_incoming")
            let request = HTTP3BackendRequest(connection: connection, backend: self.backend, identity: self.identity, queue: self.queue, spoolDirectory: self.spoolDirectory)
            self.requests.append(request)
            request.onFinish = { [weak self, weak request, weak connection] in
                self?.requests.removeAll { $0 === request }
                self?.connections.removeAll { $0 === connection }
                self?.checkDrained()
            }
            connection.stateUpdateHandler = { [weak request] state in
                print("native_http3_state=\(state)")
                if case .failed = state { request?.cancel() }
                if case .cancelled = state { request?.cancel() }
            }
            connection.start(queue: self.queue)
            request.receive()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pending = ProbeContinuation(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: pending.complete(.success(()))
                case .failed(let error): pending.complete(.failure(error))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 10) {
                pending.complete(.failure(ProbeError.stage("native listener timeout")))
            }
            listener.start(queue: queue)
        }
        let (endpoint, serverID) = try await discoverPairingActor()
        guard let credential = AFCreateSPAKEIdentity("application-service-pairing-context", "application-service-pairing-client", serverID, pin, false) else { throw ProbeError.stage("native actor credential") }
        let tls = try modernTLS()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, credential)
        let parameters = NWParameters(tls: tls)
        parameters.includePeerToPeer = true
        let system = NWActorSystem(parameters: parameters)
        actorSystem = system
        peer = try RPPairingDistributedActor.discover(endpoint, connectionParameters: parameters, using: system, invalidationHandler: nil)
        print("native_file_service_ready")
    }

    func discoverPairingActor() async throws -> (NWEndpoint, String) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_applicationServicePairing._tcp", domain: nil), using: parameters)
        self.browser = browser
        return try await withCheckedThrowingContinuation { continuation in
            let pending = ProbeContinuation(continuation)
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case .bonjour(let txt) = result.metadata,
                          txt["sn"] == self.name, let serverID = txt["sid"] else { continue }
                    if pending.complete(.success((result.endpoint, serverID))) { browser.cancel() }
                    return
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state { pending.complete(.failure(error)) }
            }
            queue.asyncAfter(deadline: .now() + 12) {
                if pending.complete(.failure(ProbeError.stage("native actor discovery timeout"))) { browser.cancel() }
            }
            browser.start(queue: queue)
        }
    }

    func resolve(publicKey: Data) async throws -> RPPairingBonjourResolveResponse {
        guard let peer else { throw ProbeError.stage("native actor unavailable") }
        let response = try await peer.resolveBonjour(clientPublicKey: publicKey)
        print("native_file_endpoint_resolved key_bytes=\(response.serverPublicKey.count)")
        return response
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.browser?.cancel()
            self.connections.forEach { $0.cancel() }
            self.requests.forEach { $0.cancel() }
            self.connections.removeAll(); self.requests.removeAll()
            self.backend.session.invalidateAndCancel()
        }
    }

    func quiesce(_ completion: @escaping () -> Void) {
        queue.async {
            self.accepting = false
            self.drained = completion
            // HTTP3 peers may pre-open idle streams without sending a request.
            // The worker calls this only after all accepted uploads finish;
            // these unclaimed streams are not transfers and must not hold the
            // restart barrier forever. Keep actual response sends until ACK.
            for request in self.requests.filter({ $0.path == nil }) { request.cancel() }
            self.checkDrained()
        }
    }
    private func checkDrained() {
        guard !accepting, requests.isEmpty, let callback = drained else { return }
        drained = nil
        callback()
    }
    func resume() {
        queue.async { self.drained = nil; self.accepting = true }
    }
    func stopAndWait() async {
        stop()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}

final class LocalReceiverBackend: NSObject, URLSessionDelegate, @unchecked Sendable {
    let port: UInt16
    init(port: UInt16? = nil) {
        self.port = port ?? UInt16(ProcessInfo.processInfo.environment["AIRFOLDER_PROBE_BACKEND_PORT"] ?? "49875") ?? 49875
        super.init()
    }
    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3600
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // The existing receiver has a self-signed certificate and is reached only on loopback.
        guard ["::1", "[::1]"].contains(challenge.protectionSpace.host), challenge.protectionSpace.port == Int(port),
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

final class HTTP3BackendRequest: @unchecked Sendable {
    let connection: NWConnection
    let backend: LocalReceiverBackend
    let identity: RPPairingTemporaryIdentity?
    let queue: DispatchQueue
    var path: String?
    var headers: [String: String] = [:]
    var body = Data()
    var spool: URL?
    var file: FileHandle?
    var bytes = 0
    var finished = false
    var upload: StreamingUpload?
    var task: URLSessionTask?
    let spoolDirectory: URL?
    var onFinish: (() -> Void)?

    init(connection: NWConnection, backend: LocalReceiverBackend, identity: RPPairingTemporaryIdentity?, queue: DispatchQueue, spoolDirectory: URL?) {
        self.connection = connection; self.backend = backend; self.identity = identity
        self.queue = queue
        self.spoolDirectory = spoolDirectory
    }
    deinit { try? file?.close() }

    func receive() {
        AFReceiveHTTP(connection.nw) { newPath, headers, data, complete, error in
            guard !self.finished else { return }
            do {
                if let newPath, self.path == nil {
                    guard ["/Discover", "/Ask", "/Upload"].contains(newPath) else { throw ProbeError.invalidArgument }
                    self.path = newPath
                    print("native_http3_request path=\(newPath)")
                }
                self.headers.merge(headers) { _, new in new }
                guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
                self.bytes += data.count
                if self.path == "/Upload" {
                    if self.file == nil, let directory = self.spoolDirectory {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        let spool = directory.appendingPathComponent(UUID().uuidString + ".body")
                        guard FileManager.default.createFile(atPath: spool.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ProbeError.stage("upload spool") }
                        self.spool = spool
                        self.file = try FileHandle(forWritingTo: spool)
                    }
                    try self.file?.write(contentsOf: data)
                    if complete {
                        try self.file?.synchronize()
                        try self.file?.close()
                        self.file = nil
                        print("native_http3_upload_source_complete bytes=\(self.bytes)")
                    }
                    try self.stream(data, complete: complete)
                    return
                } else {
                    guard self.bytes <= 8 * 1024 * 1024 else { throw ProbeError.stage("metadata too large") }
                    self.body.append(data)
                }
                guard complete else { self.receive(); return }
                self.forward()
            } catch {
                self.fail(error)
            }
        }
    }

    func stream(_ data: Data, complete: Bool) throws {
        if let upload { sendBlock(upload, data: data, complete: complete); return }
        let upload = try StreamingUpload(port: backend.port, headers: headers, queue: queue)
        self.upload = upload
        upload.onContinue = { [weak self, weak upload] in
            guard let self, let upload, !self.finished else { return }
            print("native_http3_streaming_backend_ready source_bytes=\(self.bytes) framing=\(upload.length == nil ? "chunked" : "content-length")")
            if self.headers["expect"]?.lowercased() == "100-continue" {
                guard AFSendHTTP(self.connection.nw, 100, Data(), [:], false, { error in
                    if error != 0 { self.fail(NSError(domain: NSPOSIXErrorDomain, code: Int(error))) }
                }) else { self.fail(ProbeError.stage("HTTP3 continue")); return }
            }
            self.sendBlock(upload, data: data, complete: complete)
        }
        upload.onResponse = { [weak self] status, data, headers in self?.reply(status: status, data: data, headers: headers) }
        upload.onFailure = { [weak self] error in self?.fail(error) }
        upload.start()
    }

    func sendBlock(_ upload: StreamingUpload, data: Data, complete: Bool) {
        upload.send(data, final: complete) { [weak self] error in
            guard let self, !self.finished else { return }
            if let error { self.fail(error); return }
            if !complete { self.receive() }
        }
    }

    func cancel() {
        // A terminal connection failure may race the response-send callback.
        // Release its drain reservation exactly once even after reply() marked
        // the request finished. No successful response is cut short here.
        guard !finished else { onFinish?(); onFinish = nil; return }
        finished = true
        upload?.cancel()
        task?.cancel()
        try? file?.close()
        file = nil
        body = Data()
        connection.cancel()
        onFinish?(); onFinish = nil
    }

    func fail(_ error: Error) {
        guard !finished else { return }
        print("native_http3_request_error=\(error)")
        cancel()
    }

    func reply(status: UInt32, data: Data, headers: [String: String]) {
        guard !finished else { return }
        finished = true
        try? file?.close()
        file = nil
        body = Data()
        if path == "/Upload", status == 200, let spool {
            do { try FileManager.default.removeItem(at: spool); self.spool = nil }
            catch { print("native_http3_spool_cleanup_failed") }
        }
        if !AFSendHTTP(connection.nw, status, data, headers, true, { error in
            print("native_http3_response path=\(self.path ?? "unknown") status=\(status) error=\(error)")
            self.connection.stateUpdateHandler = nil
            self.onFinish?(); self.onFinish = nil
        }) { connection.cancel(); onFinish?(); onFinish = nil }
    }

    func forward() {
        guard let path else { fail(ProbeError.invalidArgument); return }
        let url = URL(string: "https://[::1]:\(backend.port)" + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers where !["host", "connection", "transfer-encoding", "content-length", "expect"].contains(key.lowercased()) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(String(bytes), forHTTPHeaderField: "Content-Length")
        let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
            guard let response = response as? HTTPURLResponse, error == nil else {
                self.queue.async { self.fail(error ?? ProbeError.stage("backend response")) }; return
            }
            var data = data ?? Data()
            if ["/Discover", "/Ask"].contains(path), var plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                plist["ReceiverComputerName"] = self.identity?.deviceName ?? "AimDrop Logo Test"
                if path == "/Discover", let identity = self.identity {
                    plist["ReceiverDeviceIRKData"] = identity.deviceIRKData
                    plist["ReceiverEdPKData"] = identity.devicePublicKey
                }
                if let encoded = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) { data = encoded }
            }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                let name = String(describing: key)
                if !["connection", "transfer-encoding", "content-length"].contains(name.lowercased()) { headers[name] = String(describing: value) }
            }
            let result = data, resultHeaders = headers
            self.queue.async { self.reply(status: UInt32(response.statusCode), data: result, headers: resultHeaders) }
        }
        task = backend.session.uploadTask(with: request, from: body, completionHandler: completion)
        task?.resume()
    }
}

// App-owned loopback backend for the isolated, LaunchServices-launched probe.
import Foundation

final class ResearchBackend {
    let stateDirectory: URL
    let port: UInt16
    private let process: Process
    private let lifetime: Pipe
    private let output: Pipe
    private let log: FileHandle
    init() throws {
        guard let project = Bundle.main.object(forInfoDictionaryKey: "AimDropResearchProject") as? String,
              project.hasPrefix("/"),
              let state = Bundle.main.object(forInfoDictionaryKey: "AimDropResearchState") as? String,
              state.hasPrefix(project + "/.build/") else { throw ProbeError.invalidArgument }
        stateDirectory = URL(fileURLWithPath: state, isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let logURL = stateDirectory.appendingPathComponent("backend.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        process = Process()
        lifetime = Pipe()
        output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", "-u", project + "/scripts/research/remote-discovery-backend.py", state]
        process.currentDirectoryURL = URL(fileURLWithPath: project)
        process.standardInput = lifetime
        process.standardOutput = output
        process.standardError = log
        try process.run()
        // Bound startup independently of the AppKit run loop.
        let child = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [output] in
            if child.isRunning && output.fileHandleForReading.readabilityHandler == nil {
                child.terminate()
            }
        }
        var data = Data()
        while data.last != 10, data.count < 4096,
              let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            data.append(byte)
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = value["backend_port"] as? Int, let port = UInt16(exactly: number), port > 0 else {
            process.terminate()
            throw ProbeError.stage("research backend startup failed")
        }
        self.port = port
        let log = self.log
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { try? log.write(contentsOf: data) }
        }
    }
    func stop() { try? lifetime.fileHandleForWriting.close() }
    deinit { stop() }
}

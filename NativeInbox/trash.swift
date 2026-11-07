import Foundation
import Darwin

// The inherited flock remains held if the worker exits during the filesystem
// operation. A subsequent worker must wait before recovering this receipt.
let arguments = CommandLine.arguments
var result: [String: Any] = ["ok": false]
if arguments.count == 3, let fd = Int32(arguments[2]), fcntl(fd, F_GETFD) >= 0 {
    let source = URL(fileURLWithPath: arguments[1], isDirectory: true)
    do {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard source.path.hasPrefix("/"), values.isDirectory == true,
              values.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
        var destination: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
        guard let destination else { throw CocoaError(.fileWriteUnknown) }
        result = ["ok": true, "path": destination.path ?? ""]
    } catch {
        // Do not write paths or file names into diagnostic output.
        result = ["ok": false]
    }
}
if let data = try? JSONSerialization.data(withJSONObject: result) {
    FileHandle.standardOutput.write(data)
}
exit(result["ok"] as? Bool == true ? 0 : 1)

import Cocoa
import UniformTypeIdentifiers

struct TransferProgress {
    let bytes: Int64
    let totalBytes: Int64?
    let decodedBytes: Int64
    let totalDecodedBytes: Int64?
    let completedFiles: Int
    let totalFiles: Int?
    let saving: Bool

    init(event: [String: Any]) {
        bytes = (event["bytes"] as? NSNumber)?.int64Value ?? 0
        totalBytes = (event["total_bytes"] as? NSNumber)?.int64Value
        decodedBytes = (event["decoded_bytes"] as? NSNumber)?.int64Value ?? 0
        totalDecodedBytes = (event["total_decoded_bytes"] as? NSNumber)?.int64Value
        completedFiles = event["files_received"] as? Int ?? 0
        totalFiles = event["total_files"] as? Int
        saving = event["phase"] as? String == "saving"
    }

    var estimated: Bool { (totalBytes ?? 0) <= 0 && (totalDecodedBytes ?? 0) > 0 }

    var fraction: Double? {
        if let total = totalBytes, total > 0 {
            return max(0, min(0.99, Double(bytes) / Double(total)))
        }
        if let total = totalDecodedBytes, total > 0 {
            return max(0, min(0.99, Double(decodedBytes) / Double(total)))
        }
        if let total = totalFiles, total > 1, completedFiles <= total {
            return max(0, min(0.99, Double(completedFiles) / Double(total)))
        }
        return nil
    }

    var text: String {
        let received = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        var parts: [String]
        if let total = totalBytes, total > 0 {
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            parts = ["\(saving ? "Zapisano" : "Odebrano") \(received) z \(size)"]
        } else {
            parts = ["\(saving ? "Zapisano" : "Odebrano") \(received)"]
        }
        if let total = totalFiles, completedFiles <= total {
            parts.append("\(completedFiles) z \(total) plików")
        } else if completedFiles > 0 {
            parts.append("ukończono pliki: \(completedFiles)")
        }
        return parts.joined(separator: " · ")
    }
}

enum TransferItemKind { case image, video, folder, file }

enum TransferFileAction { case reveal, open }

struct TransferFileTarget {
    let paths: [String]
    let directory: String

    func perform(_ action: TransferFileAction) {
        let urls = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty {
            switch action {
            case .reveal: NSWorkspace.shared.activateFileViewerSelecting(urls)
            case .open: for url in urls { NSWorkspace.shared.open(url) }
            }
        } else if FileManager.default.fileExists(atPath: directory) {
            NSWorkspace.shared.open(URL(fileURLWithPath: directory))
        }
    }
}

enum TransferSummary {
    static func kind(_ url: URL) -> TransferItemKind {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return .folder }
        return kind(name: url.lastPathComponent)
    }

    static func kind(name: String) -> TransferItemKind {
        if let type = UTType(filenameExtension: (name as NSString).pathExtension) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        }
        return .file
    }

    static func noun(_ count: Int, _ singular: String, _ few: String, _ many: String) -> String {
        let word = count == 1 ? singular : ((2...4).contains(count % 10) && !(12...14).contains(count % 100) ? few : many)
        return "\(count) \(word)"
    }

    static func describe(names: [String], folders: Set<String> = [], fallbackCount: Int = 0) -> String {
        describe(kinds: names.map { folders.contains($0) ? .folder : kind(name: $0) }, fallbackCount: fallbackCount)
    }

    static func describe(urls: [URL], fallbackCount: Int) -> String {
        describe(kinds: urls.map { kind($0) }, fallbackCount: fallbackCount)
    }

    private static func describe(kinds: [TransferItemKind], fallbackCount: Int) -> String {
        var images = 0, videos = 0, folders = 0, files = 0
        for kind in kinds {
            switch kind {
            case .image: images += 1
            case .video: videos += 1
            case .folder: folders += 1
            case .file: files += 1
            }
        }
        if kinds.isEmpty { files = fallbackCount }
        var parts: [String] = []
        if images > 0 { parts.append(noun(images, "zdjęcie", "zdjęcia", "zdjęć")) }
        if videos > 0 { parts.append("\(videos) wideo") }
        if folders > 0 { parts.append(noun(folders, "folder", "foldery", "folderów")) }
        if files > 0 { parts.append(noun(files, "plik", "pliki", "plików")) }
        return parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " i " + parts.last! : (parts.first ?? "pliki")
    }
}

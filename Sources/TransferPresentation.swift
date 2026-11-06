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
        let received = Self.byteCount(bytes)
        var parts: [String]
        if let total = totalBytes, total > 0 {
            let size = Self.byteCount(total)
            parts = [saving ? L10n.format("Saved %@ of %@", "Zapisano %@ z %@", received, size)
                            : L10n.format("Received %@ of %@", "Odebrano %@ z %@", received, size)]
        } else {
            parts = [saving ? L10n.format("Saved %@", "Zapisano %@", received)
                            : L10n.format("Received %@", "Odebrano %@", received)]
        }
        if let total = totalFiles, completedFiles <= total {
            parts.append(L10n.plural("progress.files", count: total,
                                     total == 1 ? "%ld of %ld file" : "%ld of %ld files",
                                     total == 1 ? "%ld z %ld pliku" : "%ld z %ld plików", completedFiles, total))
        } else if completedFiles > 0 {
            parts.append(L10n.format("Completed: %@", "Ukończono: %@", TransferSummary.files(completedFiles)))
        }
        return parts.joined(separator: " · ")
    }

    private static func byteCount(_ bytes: Int64) -> String {
        // ByteCountFormatter uses the system locale, even with a manual app language.
        let units = ["B", "kB", "MB", "GB", "TB", "PB", "EB"]
        var value = Double(max(0, bytes)), unit = 0
        while value >= 1000 && unit < units.count - 1 { value /= 1000; unit += 1 }
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = unit == 0 ? 0 : (value < 10 ? 2 : 1)
        return (formatter.string(from: NSNumber(value: value)) ?? String(value)) + " " + units[unit]
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

    static func files(_ count: Int) -> String {
        L10n.plural("files", count: count, count == 1 ? "%ld file" : "%ld files",
                    polishTemplate(count, "%ld plik", "%ld pliki", "%ld plików"), count)
    }

    private static func polishTemplate(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        switch L10n.pluralCategory(count, language: .polish) {
        case "one": return one
        case "few": return few
        default: return many
        }
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
        if images > 0 { parts.append(L10n.plural("photos", count: images, images == 1 ? "%ld photo" : "%ld photos",
            polishTemplate(images, "%ld zdjęcie", "%ld zdjęcia", "%ld zdjęć"), images)) }
        if videos > 0 { parts.append(L10n.plural("videos", count: videos, videos == 1 ? "%ld video" : "%ld videos", "%ld wideo", videos)) }
        if folders > 0 { parts.append(L10n.plural("folders", count: folders, folders == 1 ? "%ld folder" : "%ld folders",
            polishTemplate(folders, "%ld folder", "%ld foldery", "%ld folderów"), folders)) }
        if files > 0 { parts.append(Self.files(files)) }
        return parts.count > 1 ? parts.dropLast().joined(separator: ", ") + L10n.text(" and ", " i ") + parts.last!
            : (parts.first ?? L10n.text("files", "pliki"))
    }
}

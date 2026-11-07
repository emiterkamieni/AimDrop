import Cocoa
import ImageIO
import QuickLookThumbnailing

enum PendingFilePreviewContent {
    case image(CGImage)
    case text(String)
    case unavailable
}

enum PendingFilePreviewLoader {
    typealias Cancel = () -> Void
    typealias Completion = (PendingFilePreviewContent) -> Void
    typealias Load = (URL, @escaping Completion) -> Cancel
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "mov", "mp4", "pdf", "doc", "docx", "txt", "gif", "webm", "webp"]
    private static let images: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp"]
    private static let queue = DispatchQueue(label: "pl.aimdrop.inbox-preview", qos: .userInitiated)

    private final class Work {
        private let lock = NSLock()
        private var canceled = false
        private var finished = false
        private var request: QLThumbnailGenerator.Request?

        var isCanceled: Bool { lock.lock(); defer { lock.unlock() }; return canceled }
        func cancel() {
            lock.lock()
            canceled = true
            let active = request
            request = nil
            lock.unlock()
            if let active { QLThumbnailGenerator.shared.cancel(active) }
        }
        func finish(_ result: PendingFilePreviewContent, completion: Completion) {
            lock.lock()
            let deliver = !canceled && !finished
            finished = true
            request = nil
            lock.unlock()
            if deliver { completion(result) }
        }
        func quickLook(_ url: URL, completion: @escaping Completion) {
            lock.lock()
            defer { lock.unlock() }
            guard !canceled else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 320, height: 240),
                                                       scale: 2, representationTypes: .thumbnail)
            self.request = request
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
                self?.finish(thumbnail.map { .image($0.cgImage) } ?? .unavailable, completion: completion)
            }
        }
    }

    static func load(_ url: URL, completion: @escaping Completion) -> Cancel {
        let work = Work()
        queue.async {
            guard !work.isCanceled else { return }
            let type = url.pathExtension.lowercased()
            guard extensions.contains(type),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                work.finish(.unavailable, completion: completion)
                return
            }
            if images.contains(type),
               let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                    kCGImageSourceShouldCacheImmediately: true
               ] as CFDictionary) {
                work.finish(.image(image), completion: completion)
            } else if type == "txt" {
                do {
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let data = try file.read(upToCount: 8192) ?? Data()
                    let unicode = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
                    let text = (unicode ? String(data: data, encoding: .utf16) : nil)
                        ?? String(decoding: data, as: UTF8.self)
                    work.finish(.text(String(text.prefix(1600))), completion: completion)
                } catch { work.finish(.unavailable, completion: completion) }
            } else {
                work.quickLook(url, completion: completion)
            }
        }
        return { work.cancel() }
    }
}

private final class PendingPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PendingFilePreviewController {
    private let panel: NSPanel
    private let image = NSImageView()
    private let text = NSTextField(wrappingLabelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let load: PendingFilePreviewLoader.Load
    private let delay: TimeInterval
    private var generation = UUID()
    private var scheduled: DispatchWorkItem?
    private var cancelLoad: PendingFilePreviewLoader.Cancel?
    private weak var anchor: NSView?
    private(set) var transferID: String?

    init(delay: TimeInterval = 0.35, load: @escaping PendingFilePreviewLoader.Load = PendingFilePreviewLoader.load) {
        self.delay = delay
        self.load = load
        let bounds = NSRect(x: 0, y: 0, width: 320, height: 264)
        panel = PendingPreviewPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSVisualEffectView(frame: bounds)
        content.material = .popover
        content.state = .active
        content.blendingMode = .behindWindow
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        panel.contentView = content
        title.frame = NSRect(x: 14, y: 232, width: 292, height: 18)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        image.frame = NSRect(x: 14, y: 14, width: 292, height: 206)
        image.imageScaling = .scaleProportionallyUpOrDown
        text.frame = image.frame
        text.font = .systemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor
        text.maximumNumberOfLines = 14
        text.lineBreakMode = .byTruncatingTail
        content.addSubview(title); content.addSubview(image); content.addSubview(text)
    }

    deinit { scheduled?.cancel(); cancelLoad?(); panel.close() }

    func schedule(url: URL, transferID: String, anchor: NSView) {
        if self.anchor === anchor && self.transferID == transferID { return }
        hide()
        guard PendingFilePreviewLoader.extensions.contains(url.pathExtension.lowercased()) else { return }
        self.anchor = anchor
        self.transferID = transferID
        let current = generation
        let work = DispatchWorkItem { [weak self, weak anchor] in
            guard let self, let anchor, anchor.window != nil, self.generation == current else { return }
            self.present(url: url, anchor: anchor)
            self.cancelLoad = self.load(url) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.generation == current, self.anchor?.window != nil else { return }
                    self.cancelLoad = nil
                    self.show(result)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.generation == current, let cancel = self.cancelLoad else { return }
                cancel()
                self.cancelLoad = nil
                // Ignore a late completion from a codec that cannot be interrupted.
                self.generation = UUID()
                self.show(.unavailable)
            }
        }
        scheduled = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide(for view: NSView? = nil) {
        if let view, anchor !== view { return }
        generation = UUID()
        scheduled?.cancel(); scheduled = nil
        cancelLoad?(); cancelLoad = nil
        anchor = nil; transferID = nil
        image.image = nil
        text.stringValue = ""
        panel.orderOut(nil)
    }

    private func present(url: URL, anchor: NSView) {
        guard let window = anchor.window else { return }
        let row = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let size = panel.frame.size
        var x = window.frame.maxX + 8
        if x + size.width > visible.maxX { x = window.frame.minX - size.width - 8 }
        x = max(visible.minX + 4, min(x, visible.maxX - size.width - 4))
        let y = max(visible.minY + 4, min(row.maxY - size.height, visible.maxY - size.height - 4))
        panel.appearance = anchor.effectiveAppearance
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        title.stringValue = url.lastPathComponent.components(separatedBy: .newlines).joined(separator: " ")
        image.isHidden = true
        text.isHidden = false
        text.font = .systemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor
        text.stringValue = L10n.text("Loading preview…", "Ładowanie podglądu…")
        panel.orderFrontRegardless()
    }

    private func show(_ content: PendingFilePreviewContent) {
        switch content {
        case .image(let bitmap):
            image.image = NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
            image.isHidden = false; text.isHidden = true
        case .text(let value):
            image.isHidden = true; text.isHidden = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.textColor = .labelColor
            text.stringValue = value
        case .unavailable:
            image.isHidden = true; text.isHidden = false
            text.font = .systemFont(ofSize: 12)
            text.textColor = .secondaryLabelColor
            text.stringValue = L10n.text("No preview is available for this file.", "Podgląd tego pliku jest niedostępny.")
        }
    }

    #if AIRFOLDER_CHECKS
    var visibleForChecks: Bool { panel.isVisible }
    var textForChecks: String { text.stringValue }
    #endif
}

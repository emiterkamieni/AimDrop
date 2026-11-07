import Cocoa
import ImageIO
import QuickLookThumbnailing

enum TransferPreview {
    static func decode(_ encoded: String) -> CGImage? {
        guard let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 120,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

private final class ProgressPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ProgressTrackView: NSView {
    private var fraction: Double?
    private var timer: Timer?
    private var started = ProcessInfo.processInfo.systemUptime

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(L10n.text("Transfer progress", "Postęp przesyłania"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate() }

    func setFraction(_ value: Double?) {
        fraction = value.map { max(0, min(1, $0)) }
        if let fraction = fraction {
            timer?.invalidate()
            timer = nil
            setAccessibilityValue("\(Int(fraction * 100))%")
        } else {
            setAccessibilityValue(L10n.text("Transfer in progress", "Trwa przesyłanie"))
            resumeAnimation()
        }
        needsDisplay = true
    }

    func resumeAnimation() {
        guard fraction == nil, timer == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self = self, self.window?.isVisible == true else {
                timer.invalidate()
                self?.timer = nil
                return
            }
            self.needsDisplay = true
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rail = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.white.withAlphaComponent(0.20).setFill()
        rail.fill()
        NSGraphicsContext.saveGraphicsState()
        rail.addClip()
        let fill: NSRect
        if let fraction = fraction {
            fill = NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        } else {
            let phase = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.5
                : (ProcessInfo.processInfo.systemUptime - started).truncatingRemainder(dividingBy: 1.8) / 1.8
            let width = bounds.width * 0.28
            fill = NSRect(x: phase * (bounds.width + width) - width, y: 0, width: width, height: bounds.height)
        }
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: fill, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class ProgressCardView: NSView {
    static let size = NSSize(width: 380, height: 128)
    private let title = NSTextField(labelWithString: "AimDrop")
    private let subtitle = NSTextField(labelWithString: L10n.text("Preparing to receive…", "Przygotowywanie odbioru…"))
    private let detail = NSTextField(labelWithString: L10n.text("Waiting for data", "Oczekiwanie na dane"))
    private let preview = NSImageView()
    private let bar = ProgressTrackView(frame: .zero)
    private let cancelButton = NSButton()
    private let revealButton = NSButton(title: L10n.text("Show in Finder", "Pokaż w Finderze"), target: nil, action: nil)
    private let openButton = NSButton(title: L10n.text("Open", "Otwórz"), target: nil, action: nil)
    private let material = NSVisualEffectView()
    var onCancel: (() -> Void)?
    var onFileAction: ((TransferFileAction) -> Void)?
    var onFirstDraw: (() -> Void)?
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        material.frame = bounds
        material.autoresizingMask = [.width, .height]
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 18
        material.layer?.borderWidth = 1
        material.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        addSubview(material)

        let icon = NSImageView(frame: NSRect(x: 11, y: 11, width: 48, height: 48))
        icon.image = AimDropArtwork.applicationIcon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("AimDrop")
        addSubview(icon)

        title.frame = NSRect(x: 66, y: 15, width: 242, height: 18)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitle.frame = NSRect(x: 66, y: 34, width: 242, height: 18)
        subtitle.font = .systemFont(ofSize: 12, weight: .regular)
        detail.frame = NSRect(x: 16, y: 73, width: 348, height: 16)
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        for label in [title, subtitle, detail] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }

        preview.frame = NSRect(x: 320, y: 14, width: 44, height: 44)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8
        preview.layer?.masksToBounds = true
        preview.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        preview.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L10n.text("Transferred files", "Przesyłane pliki"))
        preview.setAccessibilityLabel(L10n.text("Transferred files", "Przesyłane pliki"))
        preview.contentTintColor = .secondaryLabelColor
        addSubview(preview)

        bar.frame = NSRect(x: 16, y: 103, width: 324, height: 7)
        addSubview(bar)

        cancelButton.frame = NSRect(x: 347, y: 98, width: 18, height: 18)
        cancelButton.isBordered = false
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L10n.text("Cancel receiving", "Anuluj odbieranie"))
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.toolTip = L10n.text("Cancel receiving", "Anuluj odbieranie")
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        addSubview(cancelButton)

        for (index, button) in [revealButton, openButton].enumerated() {
            button.frame = NSRect(x: 16 + CGFloat(index) * 178, y: 88, width: 170, height: ActionButtonStyle.height)
            ActionButtonStyle.apply(to: button, autoLayout: false)
            button.target = self
            button.action = index == 0 ? #selector(revealClicked) : #selector(openClicked)
            button.isHidden = true
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepare(summary: String, saving: Bool) {
        bar.isHidden = false
        revealButton.isHidden = true
        openButton.isHidden = true
        title.frame.size.width = 242
        subtitle.frame.size.width = 242
        preview.frame = NSRect(x: 320, y: 14, width: 44, height: 44)
        detail.frame.origin.y = 73
        cancelButton.frame = NSRect(x: 347, y: 98, width: 18, height: 18)
        title.stringValue = "AimDrop"
        subtitle.stringValue = saving ? L10n.format("Saving (%@)", "Zapisuję (%@)", summary)
            : L10n.format("Receiving (%@)", "Odbieram (%@)", summary)
        cancelButton.isEnabled = true
        cancelButton.isHidden = false
        cancelButton.toolTip = saving ? L10n.text("Cancel saving — files will stay in the buffer", "Anuluj zapisywanie — pliki pozostaną w buforze")
            : L10n.text("Cancel receiving", "Anuluj odbieranie")
        cancelButton.setAccessibilityLabel(saving ? L10n.text("Cancel saving", "Anuluj zapisywanie") : L10n.text("Cancel receiving", "Anuluj odbieranie"))
    }

    func setPreview(_ image: CGImage) {
        preview.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        preview.contentTintColor = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let callback = onFirstDraw
        onFirstDraw = nil
        callback?()
    }

    func update(_ progress: TransferProgress) {
        detail.stringValue = progress.text
        detail.toolTip = progress.estimated ? L10n.text("Estimated progress based on the archive size reported by the sender.", "Szacowany postęp według rozmiaru archiwum podanego przez nadawcę.") : progress.text
        bar.setAccessibilityLabel(progress.estimated ? L10n.text("Estimated transfer progress", "Szacowany postęp przesyłania") : L10n.text("Transfer progress", "Postęp przesyłania"))
        bar.setFraction(progress.fraction)
    }

    func finish(saving: Bool, awaitingDestination: Bool) {
        bar.setFraction(1)
        detail.stringValue = saving ? L10n.text("Save complete", "Zapis zakończony") : (awaitingDestination
            ? L10n.text("Transfer complete — choose a save folder", "Transfer zakończony — wybierz folder zapisu")
            : L10n.text("Files received — preparing to save", "Pliki odebrane — przygotowywanie zapisu"))
        cancelButton.isHidden = true
    }

    func completed(summary: String, directory: String) {
        title.stringValue = L10n.text("Received via AirDrop", "Odebrano przez AirDrop")
        subtitle.stringValue = L10n.format("Received (%@)", "Odebrano (%@)", summary)
        title.frame.size.width = 230
        subtitle.frame.size.width = 230
        preview.frame = NSRect(x: 304, y: 18, width: 38, height: 38)
        detail.frame.origin.y = 65
        detail.stringValue = L10n.format("Saved to: %@", "Zapisano w: %@", URL(fileURLWithPath: directory).lastPathComponent)
        detail.toolTip = directory
        bar.setFraction(1)
        bar.isHidden = true
        revealButton.isHidden = false
        openButton.isHidden = false
        cancelButton.frame = NSRect(x: 348, y: 12, width: 18, height: 18)
        cancelButton.isEnabled = true
        cancelButton.isHidden = false
        cancelButton.toolTip = L10n.text("Dismiss notification", "Zamknij powiadomienie")
        cancelButton.setAccessibilityLabel(L10n.text("Dismiss notification", "Zamknij powiadomienie"))
    }

    func cancelling() {
        cancelButton.isEnabled = false
        detail.stringValue = L10n.text("Canceling…", "Anulowanie…")
    }

    func refreshLocalization(summary: String, saving: Bool, progress: TransferProgress,
                             directory: String?, awaitingDestination: Bool?) {
        let wasCancelling = !cancelButton.isEnabled
        revealButton.title = L10n.text("Show in Finder", "Pokaż w Finderze")
        openButton.title = L10n.text("Open", "Otwórz")
        preview.setAccessibilityLabel(L10n.text("Transferred files", "Przesyłane pliki"))
        if let directory { completed(summary: summary, directory: directory) }
        else {
            prepare(summary: summary, saving: saving)
            update(progress)
            if let awaitingDestination { finish(saving: saving, awaitingDestination: awaitingDestination) }
            else if wasCancelling { cancelling() }
        }
    }

    @objc private func cancelClicked() {
        if revealButton.isHidden { cancelling() }
        onCancel?()
    }
    @objc private func revealClicked() { onFileAction?(.reveal) }
    @objc private func openClicked() { onFileAction?(.open) }

    func resumeAnimation() { bar.resumeAnimation() }

    func previewImage() -> NSBitmapImageRep? {
        // A material fallback lets an offscreen preview render without capturing the desktop.
        material.blendingMode = .withinWindow
        layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1).cgColor
        layoutSubtreeIfNeeded()
        displayIfNeeded()
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }
}

final class TransferProgressBanners: NSObject {
    private final class Banner {
        let panel: ProgressPanel
        let view: ProgressCardView
        var names: [String] = []
        var folders: Set<String> = []
        var count = 0
        var summary: String { TransferSummary.describe(names: names, folders: folders, fallbackCount: count) }
        var progress = TransferProgress(event: [:])
        var awaitingDestination: Bool?
        var saving = false
        var generation = 0
        var previewGeneration = 0
        var presented = false
        var target: TransferFileTarget?
        var thumbnailRequest: QLThumbnailGenerator.Request?

        init() {
            view = ProgressCardView()
            panel = ProgressPanel(contentRect: NSRect(origin: .zero, size: ProgressCardView.size),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.contentView = view
            panel.title = L10n.text("AimDrop — transfer progress", "AimDrop — postęp przesyłania")
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private var banners: [String: Banner] = [:]
    private var order: [String] = []
    private let previewQueue = DispatchQueue(label: "pl.airfrajer.preview", qos: .utility)
    private let previewDecoder: (String) -> CGImage?
    var onCancel: ((String, Bool) -> Void)?
    var onFileAction: (TransferFileAction, TransferFileTarget) -> Void = { action, target in target.perform(action) }
    var log: ((String) -> Void)?

    init(previewDecoder: @escaping (String) -> CGImage? = TransferPreview.decode) {
        self.previewDecoder = previewDecoder
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(positionPanels),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLocalization), name: L10n.didChangeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func refreshLocalization() {
        for banner in banners.values {
            banner.panel.title = banner.target == nil ? L10n.text("AimDrop — transfer progress", "AimDrop — postęp przesyłania")
                : L10n.text("AimDrop — files received", "AimDrop — pliki odebrane")
            banner.view.refreshLocalization(summary: banner.summary, saving: banner.saving, progress: banner.progress,
                                            directory: banner.target?.directory, awaitingDestination: banner.awaitingDestination)
        }
    }

    private func banner(id: String) -> Banner {
        if let existing = banners[id] { return existing }
        let banner = Banner()
        banner.view.onFirstDraw = { [weak self] in
            self?.log?("Progress card drawn transfer=\(id)")
        }
        banner.view.onCancel = { [weak self, weak banner] in
            guard let self = self, let banner = banner else { return }
            if banner.target != nil { self.remove(id: id) }
            else { self.onCancel?(id, banner.saving) }
        }
        banner.view.onFileAction = { [weak self, weak banner] action in
            guard let self = self, let target = banner?.target else { return }
            self.remove(id: id)
            self.onFileAction(action, target)
        }
        banners[id] = banner
        order.insert(id, at: 0)
        return banner
    }

    func incoming(_ event: [String: Any]) {
        guard let id = event["id"] as? String else { return }
        let banner = banner(id: id)
        banner.generation += 1
        banner.previewGeneration += 1
        banner.names = event["files"] as? [String] ?? []
        banner.folders = Set(event["folders"] as? [String] ?? [])
        banner.saving = false
        banner.awaitingDestination = nil
        banner.progress = TransferProgress(event: [:])
        banner.view.prepare(summary: banner.summary, saving: false)
        banner.view.update(banner.progress)
        positionPanels()
        // Display the card before decoding sender-supplied media. ImageIO may
        // need to initialize a codec; that must not delay the UI or IPC events.
        if let preview = event["preview"] as? String {
            let generation = banner.previewGeneration
            let decode = previewDecoder
            previewQueue.async { [weak self, weak banner] in
                let start = ProcessInfo.processInfo.systemUptime
                let image = decode(preview)
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                DispatchQueue.main.async { [weak self, weak banner] in
                    guard let self = self, let banner = banner,
                          self.banners[id] === banner, banner.previewGeneration == generation else { return }
                    if let image = image { banner.view.setPreview(image) }
                    self.log?("Preview decoded transfer=\(id) ms=\(String(format: "%.1f", elapsed)) valid=\(image != nil)")
                }
            }
        }
    }

    func begin(id: String, progress: TransferProgress, receipt: [String: Any]? = nil) {
        let banner = banner(id: id)
        banner.generation += 1
        banner.saving = progress.saving
        banner.progress = progress
        banner.awaitingDestination = nil
        if let receipt = receipt {
            let urls = (receipt["paths"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
            banner.names = urls.map { $0.lastPathComponent }
            banner.folders = Set(urls.filter { TransferSummary.kind($0) == .folder }.map { $0.lastPathComponent })
            banner.count = receipt["count"] as? Int ?? 0
        } else if banner.names.isEmpty, let count = progress.totalFiles {
            banner.count = count
        }
        banner.view.prepare(summary: banner.summary, saving: progress.saving)
        banner.view.update(progress)
        positionPanels()
    }

    func update(id: String, progress: TransferProgress) {
        guard let banner = banners[id], banner.target == nil else { return }
        banner.progress = progress
        banner.view.update(progress)
    }

    func finish(id: String, awaitingDestination: Bool = true) {
        guard let banner = banners[id], banner.target == nil else { return }
        banner.generation += 1
        let generation = banner.generation
        banner.awaitingDestination = awaitingDestination
        banner.view.finish(saving: banner.saving, awaitingDestination: awaitingDestination)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self, weak banner] in
            guard let self = self, let banner = banner,
                  self.banners[id] === banner, banner.generation == generation else { return }
            self.remove(id: id)
        }
    }

    func completed(id: String, target: TransferFileTarget, count: Int) {
        let banner = banner(id: id)
        banner.generation += 1  // Invalidate the short-lived progress completion timer.
        banner.previewGeneration += 1
        banner.target = target
        banner.panel.title = L10n.text("AimDrop — files received", "AimDrop — pliki odebrane")
        let urls = target.paths.map { URL(fileURLWithPath: $0) }
        if banner.names.isEmpty {
            banner.names = urls.map { $0.lastPathComponent }
            banner.count = count
        }
        banner.view.completed(summary: banner.summary, directory: target.directory)
        positionPanels()
        log?("Completion panel presented transfer=\(id)")
        // Quick Look is optional and asynchronous; both actions are already available.
        if let old = banner.thumbnailRequest { QLThumbnailGenerator.shared.cancel(old) }
        banner.thumbnailRequest = nil
        guard let url = urls.first(where: { TransferSummary.kind(name: $0.lastPathComponent) == .image || TransferSummary.kind(name: $0.lastPathComponent) == .video }) else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 120, height: 120),
                                                   scale: 1, representationTypes: .thumbnail)
        banner.thumbnailRequest = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self, weak banner] thumbnail, _ in
            DispatchQueue.main.async {
                guard let self = self, let banner = banner,
                      self.banners[id] === banner, banner.thumbnailRequest === request else { return }
                banner.thumbnailRequest = nil
                if let thumbnail = thumbnail { banner.view.setPreview(thumbnail.cgImage) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak banner] in
            guard let self = self, let banner = banner,
                  self.banners[id] === banner, banner.thumbnailRequest === request else { return }
            QLThumbnailGenerator.shared.cancel(request)
            banner.thumbnailRequest = nil
        }
    }

    func remove(id: String) {
        guard let banner = banners.removeValue(forKey: id) else { return }
        if let request = banner.thumbnailRequest { QLThumbnailGenerator.shared.cancel(request) }
        banner.panel.orderOut(nil)
        banner.panel.close()
        order.removeAll { $0 == id }
        positionPanels()
    }

    func closeAll() { for id in Array(banners.keys) { remove(id: id) } }

    @objc private func positionPanels() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = ProgressCardView.size
        let capacity = max(1, Int((visible.height - 28) / (size.height + 12)))
        for (index, id) in order.enumerated() {
            guard let banner = banners[id] else { continue }
            if index >= capacity { banner.panel.orderOut(nil); continue }
            let origin = NSPoint(x: visible.maxX - size.width - 16,
                                 y: visible.maxY - size.height - 14 - CGFloat(index) * (size.height + 12))
            banner.panel.setFrameOrigin(origin)
            banner.panel.orderFrontRegardless()
            banner.view.resumeAnimation()
            if !banner.presented {
                banner.presented = true
                banner.panel.displayIfNeeded()
                log?("Progress panel presented transfer=\(id) visible=\(banner.panel.isVisible)")
            }
        }
    }

    static func renderPreview(to url: URL, completion: Bool = false) throws {
        let banner = Banner()
        if completion {
            banner.view.completed(summary: TransferSummary.describe(names: ["clip.mov"]), directory: "/Example/Filmy")
        } else {
            banner.view.prepare(summary: TransferSummary.describe(names: Array(repeating: "photo.jpg", count: 9) + ["clip.mov"]), saving: false)
            banner.view.update(TransferProgress(event: ["bytes": 46_000_000, "total_bytes": 100_000_000,
                                                       "files_received": 4, "total_files": 10]))
        }
        guard let bitmap = banner.view.previewImage(), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "AimDrop", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.text("Could not render the preview.", "Nie udało się wyrenderować podglądu.")])
        }
        try png.write(to: url)
        banner.panel.close()
    }
}

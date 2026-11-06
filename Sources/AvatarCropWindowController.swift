import Cocoa

final class AvatarPreviewView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 88, height: 88) }
    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 1, dy: 1)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: circle).addClip()
        NSColor.controlBackgroundColor.setFill()
        circle.fill()
        image?.draw(in: circle, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        NSBezierPath(ovalIn: circle).stroke()
    }
}

private final class AvatarCropView: NSView {
    var crop: AvatarCrop { didSet { needsDisplay = true } }
    private var lastPoint: NSPoint?
    init(image: CGImage) { crop = AvatarCrop(image: image); super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 280, height: 280) }
    private var circle: NSRect { bounds.insetBy(dx: 12, dy: 12) }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: circle).addClip()
        NSColor.controlBackgroundColor.setFill()
        circle.fill()
        if let context = NSGraphicsContext.current?.cgContext {
            context.interpolationQuality = .high
            context.draw(crop.image, in: crop.imageRect(in: circle))
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        NSBezierPath(ovalIn: circle).stroke()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        lastPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let lastPoint { crop.move(dx: (point.x - lastPoint.x) / circle.width, dy: (point.y - lastPoint.y) / circle.height) }
        lastPoint = point
    }
    override func mouseUp(with event: NSEvent) { lastPoint = nil; NSCursor.pop() }
}

final class AvatarCropWindowController: NSWindowController {
    private let cropView: AvatarCropView
    private let zoom = NSSlider(value: 1, minValue: 1, maxValue: 4, target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()
    private let useButton = NSButton()
    private var cropError: Error?
    private var completion: ((ReceiverAvatar?) -> Void)?
    private var selected: ReceiverAvatar?

    init(image: CGImage) {
        cropView = AvatarCropView(image: image)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 430),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView()
        stack.orientation = .vertical; stack.spacing = 12; stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        zoom.target = self; zoom.action = #selector(zoomChanged)
        zoom.isContinuous = true
        message.alignment = .center; message.font = .systemFont(ofSize: 12); message.textColor = .secondaryLabelColor
        zoomLabel.font = .systemFont(ofSize: 12)
        let zoomRow = NSStackView(views: [zoomLabel, zoom]); zoomRow.spacing = 12
        cancelButton.target = self; cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"; cancelButton.bezelStyle = .rounded
        useButton.target = self; useButton.action = #selector(accept)
        useButton.keyEquivalent = "\r"; useButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [cancelButton, useButton]); buttons.spacing = 8
        for view in [cropView, message, zoomRow, buttons] { stack.addArrangedSubview(view) }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12),
            stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            cropView.widthAnchor.constraint(equalToConstant: 280), cropView.heightAnchor.constraint(equalToConstant: 280),
            message.widthAnchor.constraint(equalToConstant: 352), zoomRow.widthAnchor.constraint(equalToConstant: 320)
        ])
        refreshLocalization()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLocalization), name: L10n.didChangeNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func refreshLocalization() {
        window?.title = L10n.text("Adjust avatar", "Dopasuj awatar")
        zoom.setAccessibilityLabel(L10n.text("Avatar zoom", "Przybliżenie awatara"))
        zoomLabel.stringValue = L10n.text("Zoom", "Przybliżenie")
        cancelButton.title = L10n.text("Cancel", "Anuluj")
        useButton.title = L10n.text("Use avatar", "Użyj awatara")
        message.stringValue = cropError?.localizedDescription ?? L10n.text("Drag the photo to adjust the crop.", "Przeciągnij zdjęcie, aby ustawić kadr.")
    }
    func present(on parent: NSWindow, completion: @escaping (ReceiverAvatar?) -> Void) {
        self.completion = completion
        guard let window else { completion(nil); return }
        parent.beginSheet(window) { [weak self] _ in
            guard let self else { return }
            self.completion?(self.selected)
            self.completion = nil
        }
    }
    @objc private func zoomChanged() { cropView.crop.setZoom(CGFloat(zoom.doubleValue)) }
    @objc private func cancel() { finish() }
    @objc private func accept() {
        do { selected = try cropView.crop.avatar(); finish() }
        catch { cropError = error; refreshLocalization(); message.textColor = .systemRed }
    }
    private func finish() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
    }
}

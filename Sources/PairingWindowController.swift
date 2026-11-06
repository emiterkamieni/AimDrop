import Cocoa

/// App-owned PIN presentation. Never writes the code to diagnostics/defaults.
final class PairingWindowController: NSObject {
    private var window: NSPanel?
    private var expiry: Timer?
    private var heading: NSTextField?
    private var detail: NSTextField?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLocalization), name: L10n.didChangeNotification, object: nil)
    }
    deinit { expiry?.invalidate(); NotificationCenter.default.removeObserver(self) }

    @objc func refreshLocalization() {
        window?.title = L10n.text("AimDrop — pairing", "AimDrop — parowanie")
        heading?.stringValue = L10n.text("Enter this code on your iPhone", "Wpisz ten kod na iPhonie")
        detail?.stringValue = L10n.text("Pairing will be remembered. The code is needed for the first connection or after pairing expires.", "Parowanie zostanie zapamiętane. Kod jest potrzebny przy pierwszym połączeniu lub po wygaśnięciu parowania.")
    }

    func show(code: String) {
        guard code.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { return }
        close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 236),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let image = NSImageView(frame: NSRect(x: 24, y: 145, width: 56, height: 56))
        image.image = AimDropArtwork.applicationIcon
        let heading = NSTextField(wrappingLabelWithString: "")
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        heading.maximumNumberOfLines = 2
        heading.frame = NSRect(x: 96, y: 145, width: 322, height: 56)
        let digits = NSTextField(labelWithString: code)
        digits.font = .monospacedDigitSystemFont(ofSize: 46, weight: .semibold)
        digits.alignment = .center
        digits.textColor = .systemBlue
        digits.frame = NSRect(x: 24, y: 70, width: 392, height: 64)
        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.frame = NSRect(x: 26, y: 10, width: 388, height: 50)
        for view in [image, heading, digits, detail] { panel.contentView?.addSubview(view) }
        panel.center()
        window = panel
        self.heading = heading; self.detail = detail
        refreshLocalization()
        panel.orderFrontRegardless()
        expiry = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in self?.close() }
    }
    func close() {
        expiry?.invalidate(); expiry = nil
        window?.close(); window = nil
        heading = nil; detail = nil
    }
}

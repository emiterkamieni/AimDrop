import Cocoa

/// App-owned PIN presentation. Never writes the code to diagnostics/defaults.
final class PairingWindowController {
    private var window: NSPanel?
    private var expiry: Timer?

    func show(code: String) {
        guard code.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { return }
        close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 236),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "AirFolder — parowanie"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let image = NSImageView(frame: NSRect(x: 24, y: 145, width: 56, height: 56))
        image.image = AirFolderArtwork.applicationIcon
        let heading = NSTextField(labelWithString: "Wpisz ten kod na iPhonie")
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        heading.frame = NSRect(x: 96, y: 161, width: 322, height: 30)
        let digits = NSTextField(labelWithString: code)
        digits.font = .monospacedDigitSystemFont(ofSize: 46, weight: .semibold)
        digits.alignment = .center
        digits.textColor = .systemBlue
        digits.frame = NSRect(x: 24, y: 70, width: 392, height: 64)
        let detail = NSTextField(wrappingLabelWithString: "Parowanie zostanie zapamiętane. Kod jest potrzebny przy pierwszym połączeniu lub po wygaśnięciu parowania.")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.frame = NSRect(x: 26, y: 20, width: 388, height: 38)
        for view in [image, heading, digits, detail] { panel.contentView?.addSubview(view) }
        panel.center()
        window = panel
        panel.orderFrontRegardless()
        expiry = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in self?.close() }
    }
    func close() {
        expiry?.invalidate(); expiry = nil
        window?.close(); window = nil
    }
}

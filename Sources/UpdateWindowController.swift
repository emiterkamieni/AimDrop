import Cocoa

final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let primary = NSButton()
    private let secondary = NSButton()
    private let notes = NSButton()
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?
    private var notesURL: URL?
    private var extraAction: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 250),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AimDrop"
        #if AIMDROP_UPDATE_EXPERIMENT
        window.title = "AimDrop — TEST AKTUALIZACJI"
        #endif
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        detail.textColor = .secondaryLabelColor
        progress.style = .bar
        for button in [primary, secondary, notes] { ActionButtonStyle.apply(to: button) }
        primary.target = self; primary.action = #selector(accept)
        secondary.target = self; secondary.action = #selector(cancel)
        secondary.keyEquivalent = "\u{1b}"
        notes.target = self; notes.action = #selector(openNotes)
        let actions = NSStackView(views: [notes, secondary, primary])
        actions.spacing = 8
        let stack = NSStackView(views: [heading, detail, progress, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(title: String, message: String, fraction: Double? = nil, working: Bool = false,
              actionTitle: String? = nil, action: (() -> Void)? = nil,
              cancelTitle: String? = nil, cancel: (() -> Void)? = nil, releaseURL: URL? = nil,
              extraTitle: String? = nil, extra: (() -> Void)? = nil) {
        heading.stringValue = title; detail.stringValue = message
        primaryAction = action; secondaryAction = cancel; notesURL = releaseURL
        extraAction = extra
        primary.title = actionTitle ?? ""; primary.isHidden = actionTitle == nil
        secondary.title = cancelTitle ?? ""; secondary.isHidden = cancelTitle == nil
        notes.title = extraTitle ?? L10n.text("Release notes", "Opis zmian"); notes.isHidden = releaseURL == nil && extraTitle == nil
        updateProgress(fraction, visible: working)
        window?.standardWindowButton(.closeButton)?.isEnabled = cancel != nil
        let screen = window?.isVisible == true ? window?.screen : WindowPlacement.activeScreen()
        window?.contentView?.layoutSubtreeIfNeeded()
        if let window, let stack = window.contentView?.subviews.first {
            window.setContentSize(NSSize(width: max(500, stack.fittingSize.width + 48), height: stack.fittingSize.height + 48))
        }
        WindowPlacement.center(window!, on: screen)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func updateProgress(_ fraction: Double?, visible: Bool = true) {
        progress.isHidden = !visible
        progress.isIndeterminate = fraction == nil
        if let fraction { progress.stopAnimation(nil); progress.doubleValue = min(1, max(0, fraction)) * 100 }
        else if visible { progress.startAnimation(nil) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { secondaryAction?(); return false }
    @objc private func accept() { primaryAction?() }
    @objc private func cancel() { secondaryAction?() }
    @objc private func openNotes() { if let extraAction { extraAction() } else if let notesURL { NSWorkspace.shared.open(notesURL) } }
    #if AIMDROP_UPDATE_EXPERIMENT
    func acceptForExperiment() { primary.performClick(nil) }
    #endif
}

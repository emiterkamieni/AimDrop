import Cocoa
import UniformTypeIdentifiers
import ServiceManagement

private final class SettingsGroupView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let nameField = NSTextField(string: "")
    private let askToSaveButton = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let automaticSaveButton = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let folderRow = NSStackView()
    private let languageMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languageChoices = AppLanguage.allCases
    private let nameLabel = NSTextField(labelWithString: "")
    private let nameHint = NSTextField(wrappingLabelWithString: "")
    private let saveLabel = NSTextField(labelWithString: "")
    private let folderHint = NSTextField(wrappingLabelWithString: "")
    private let languageLabel = NSTextField(labelWithString: "")
    private let applicationLabel = NSTextField(labelWithString: "")
    private let updatesHint = NSTextField(wrappingLabelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let updateNotificationsButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private var contentStack: NSStackView?
    private var footerStack: NSStackView?
    private let scrollView = NSScrollView()
    private let folderLabel = NSTextField(labelWithString: "Nie wybrano folderu")
    private let chooseButton = NSButton(title: "Wybierz…", target: nil, action: nil)
    private let soundButton = NSButton(checkboxWithTitle: "Dźwięk po zapisaniu plików", target: nil, action: nil)
    private let loginItemButton = NSButton(checkboxWithTitle: "Uruchamiaj przy logowaniu", target: nil, action: nil)
    private let loginItemSettingsButton = NSButton(title: "Ustawienia macOS…", target: nil, action: nil)
    private let loginItemStatus = NSTextField(wrappingLabelWithString: "")
    private let loginItems: LoginItemManager
    private var loginItemDraft: Bool?
    private var loginItemError: Error?
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Zapisz", target: nil, action: nil)
    private var destination: SaveDestination?
    private var avatarPNG: Data?
    private let avatarPreview = AvatarPreviewView()
    private let avatarButton = NSButton(title: "Wybierz zdjęcie…", target: nil, action: nil)
    private let resetAvatarButton = NSButton(title: "Przywróć logo", target: nil, action: nil)
    private var cropController: AvatarCropWindowController?
    private let imageQueue = DispatchQueue(label: "pl.airfolder.avatar", qos: .userInitiated)
    private var picker: NSOpenPanel?
    private var hasUnsavedChanges = false
    private(set) var isChoosingFile = false
    var onSave: ((AppPreferences) -> Bool)?
    var canChooseFile: (() -> Bool)?
    var onPickerClosed: (() -> Void)?

    init(loginItems: LoginItemManager = .system) {
        self.loginItems = loginItems
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        contentStack = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)
        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18)
        ])

        avatarButton.target = self; avatarButton.action = #selector(chooseAvatar)
        resetAvatarButton.target = self; resetAvatarButton.action = #selector(resetAvatar)
        avatarButton.bezelStyle = .rounded; resetAvatarButton.bezelStyle = .rounded
        avatarPreview.setAccessibilityElement(true)
        avatarPreview.setAccessibilityRole(.image)
        avatarPreview.identifier = NSUserInterfaceItemIdentifier("avatarPreview")
        let avatarButtons = NSStackView(views: [avatarButton, resetAvatarButton]); avatarButtons.spacing = 8
        for button in [avatarButton, resetAvatarButton] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12)
        }
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .secondaryLabelColor
        nameField.placeholderString = "AimDrop"
        nameField.delegate = self
        nameField.font = .systemFont(ofSize: 16, weight: .medium)
        nameField.identifier = NSUserInterfaceItemIdentifier("receiverName")
        let avatarText = NSStackView(views: [nameLabel, nameField, avatarButtons])
        avatarText.orientation = .vertical; avatarText.alignment = .leading; avatarText.spacing = 8
        let avatarRow = NSStackView(views: [avatarPreview, avatarText]); avatarRow.spacing = 18; avatarRow.alignment = .centerY
        stack.addArrangedSubview(avatarRow)
        avatarRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        avatarText.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -90).isActive = true
        nameField.widthAnchor.constraint(equalTo: avatarText.widthAnchor).isActive = true
        avatarPreview.widthAnchor.constraint(equalToConstant: 72).isActive = true
        avatarPreview.heightAnchor.constraint(equalToConstant: 72).isActive = true
        stack.setCustomSpacing(10, after: avatarRow)
        styleHint(nameHint)
        stack.addArrangedSubview(nameHint)
        nameHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: nameHint)

        saveLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(saveLabel)
        let receiving = addGroup(to: stack)
        askToSaveButton.state = .on
        askToSaveButton.identifier = NSUserInterfaceItemIdentifier("askToSave")
        automaticSaveButton.identifier = NSUserInterfaceItemIdentifier("automaticSave")
        for button in [askToSaveButton, automaticSaveButton] {
            button.target = self
            button.action = #selector(modeChanged(_:))
            receiving.addArrangedSubview(button)
        }

        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.maximumNumberOfLines = 1
        folderLabel.font = .systemFont(ofSize: 12)
        chooseButton.target = self
        chooseButton.action = #selector(chooseFolder)
        chooseButton.bezelStyle = .rounded
        folderRow.addArrangedSubview(folderLabel)
        folderRow.addArrangedSubview(chooseButton)
        folderRow.alignment = .centerY
        folderRow.spacing = 12
        folderRow.identifier = NSUserInterfaceItemIdentifier("automaticSaveFolder")
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseButton.setContentHuggingPriority(.required, for: .horizontal)
        receiving.addArrangedSubview(folderRow)
        folderRow.widthAnchor.constraint(equalTo: receiving.widthAnchor).isActive = true
        styleHint(folderHint)
        receiving.addArrangedSubview(folderHint)
        folderHint.widthAnchor.constraint(equalTo: receiving.widthAnchor).isActive = true
        addDivider(to: receiving)

        soundButton.target = self
        soundButton.action = #selector(changed)
        receiving.addArrangedSubview(soundButton)

        applicationLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(applicationLabel)
        let application = addGroup(to: stack)

        languageLabel.font = .systemFont(ofSize: 13)
        languageMenu.target = self
        languageMenu.action = #selector(changed)
        languageMenu.identifier = NSUserInterfaceItemIdentifier("appLanguage")
        let languageRow = NSStackView(views: [languageLabel, flexibleSpace(), languageMenu])
        languageRow.spacing = 12
        languageRow.alignment = .centerY
        application.addArrangedSubview(languageRow)
        languageRow.widthAnchor.constraint(equalTo: application.widthAnchor).isActive = true
        languageMenu.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        languageMenu.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        languageMenu.setContentCompressionResistancePriority(.required, for: .horizontal)
        addDivider(to: application)

        loginItemButton.target = self
        loginItemButton.action = #selector(loginItemChanged)
        loginItemButton.identifier = NSUserInterfaceItemIdentifier("launchAtLogin")
        loginItemSettingsButton.target = self
        loginItemSettingsButton.action = #selector(openLoginItemSettings)
        loginItemSettingsButton.bezelStyle = .rounded
        loginItemSettingsButton.controlSize = .small
        loginItemSettingsButton.font = .systemFont(ofSize: 11)
        loginItemSettingsButton.isHidden = true
        application.addArrangedSubview(loginItemButton)
        application.addArrangedSubview(loginItemSettingsButton)
        loginItemStatus.font = .systemFont(ofSize: 11)
        loginItemStatus.maximumNumberOfLines = 3
        loginItemStatus.lineBreakMode = .byTruncatingTail
        loginItemStatus.identifier = NSUserInterfaceItemIdentifier("loginItemStatus")
        application.addArrangedSubview(loginItemStatus)
        loginItemStatus.widthAnchor.constraint(equalTo: application.widthAnchor).isActive = true

        versionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        updateNotificationsButton.target = self
        updateNotificationsButton.action = #selector(changed)
        updateNotificationsButton.identifier = NSUserInterfaceItemIdentifier("updateNotifications")
        application.addArrangedSubview(updateNotificationsButton)
        application.setCustomSpacing(3, after: updateNotificationsButton)
        styleHint(updatesHint)
        application.addArrangedSubview(updatesHint)
        updatesHint.widthAnchor.constraint(equalTo: application.widthAnchor).isActive = true

        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        feedback.maximumNumberOfLines = 0
        feedback.isHidden = true
        stack.addArrangedSubview(feedback)
        feedback.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        closeButton.target = self
        closeButton.action = #selector(closeSettings)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        let buttons = NSStackView(views: [versionLabel, flexibleSpace(), closeButton, saveButton])
        footerStack = buttons
        buttons.spacing = 8
        buttons.alignment = .centerY
        closeButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        saveButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
        relocalize()
    }

    private func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func addGroup(to stack: NSStackView) -> NSStackView {
        let background = SettingsGroupView()
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 8
        group.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(group)
        stack.addArrangedSubview(background)
        NSLayoutConstraint.activate([
            background.widthAnchor.constraint(equalTo: stack.widthAnchor),
            group.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            group.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            group.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            group.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14)
        ])
        stack.setCustomSpacing(18, after: background)
        return group
    }

    private func addDivider(to stack: NSStackView) {
        let divider = NSBox()
        divider.boxType = .separator
        stack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func styleHint(_ view: NSTextField) {
        view.font = .systemFont(ofSize: 11)
        view.textColor = .secondaryLabelColor
    }

    func relocalize() {
        window?.title = L10n.text("AimDrop Settings", "Ustawienia AimDrop")
        nameLabel.stringValue = L10n.text("AirDrop name", "Nazwa w AirDrop")
        nameField.setAccessibilityLabel(L10n.text("AirDrop receiver name", "Nazwa widoczna w AirDrop"))
        avatarPreview.setAccessibilityLabel(L10n.text("AirDrop receiver avatar", "Awatar odbiorcy w AirDrop"))
        avatarButton.title = L10n.text("Choose image…", "Wybierz zdjęcie…")
        resetAvatarButton.title = L10n.text("Reset logo", "Przywróć logo")
        nameHint.stringValue = L10n.text("Changing the name or avatar requires a new PIN.", "Zmiana nazwy lub awatara wymaga nowego PIN-u.")
        saveLabel.stringValue = L10n.text("Save received files", "Zapisywanie odebranych plików")
        askToSaveButton.title = L10n.text("Ask for a folder after each transfer", "Pytaj o folder po każdym odbiorze")
        automaticSaveButton.title = L10n.text("Automatically save to a folder", "Automatycznie do wybranego folderu")
        chooseButton.title = L10n.text("Choose…", "Wybierz…")
        folderHint.stringValue = L10n.text("Files you haven't saved stay in the inbox.", "Pliki oczekujące na zapis pozostają w buforze.")
        soundButton.title = L10n.text("Play a sound after saving", "Dźwięk po zapisaniu plików")
        loginItemButton.title = L10n.text("Launch at login", "Uruchamiaj przy logowaniu")
        loginItemSettingsButton.title = L10n.text("macOS Settings…", "Ustawienia macOS…")
        languageLabel.stringValue = L10n.text("Language", "Język")
        applicationLabel.stringValue = L10n.text("Application", "Aplikacja")
        let selectedLanguage = max(0, languageMenu.indexOfSelectedItem)
        languageMenu.removeAllItems()
        languageMenu.addItems(withTitles: languageChoices.map(\.nativeName))
        languageMenu.selectItem(at: selectedLanguage)
        languageMenu.setAccessibilityLabel(L10n.text("Application language", "Język aplikacji"))
        versionLabel.stringValue = L10n.format("Version %@", "Wersja %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        updateNotificationsButton.title = L10n.text("Notify about new versions", "Powiadamiaj o nowych wersjach")
        updatesHint.stringValue = L10n.text("Checks for updates every 24 hours.", "Sprawdza aktualizacje co 24 godziny.")
        closeButton.title = L10n.text("Close", "Zamknij")
        saveButton.title = L10n.text("Save", "Zapisz")
        refreshFolder()
        refreshLoginItem()
    }

    private func resizeToFit() {
        guard let window, let content = window.contentView, let contentStack, let footerStack else { return }
        content.layoutSubtreeIfNeeded()
        let naturalHeight = ceil(contentStack.fittingSize.height + footerStack.fittingSize.height + 62)
        let screen = (window.isVisible ? window.screen : WindowPlacement.activeScreen()) ?? NSScreen.main
        let titleHeight = window.frame.height - content.bounds.height
        let height = min(naturalHeight, screen.map { $0.visibleFrame.height - titleHeight } ?? naturalHeight)
        guard abs(content.bounds.height - height) > 1 else { return }
        let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 560, height: height))
        let originY = screen.map { min(max(window.frame.maxY - frame.height, $0.visibleFrame.minY), $0.visibleFrame.maxY - frame.height) }
            ?? (window.frame.maxY - frame.height)
        window.setFrame(NSRect(x: window.frame.minX, y: originY,
                               width: frame.width, height: frame.height), display: window.isVisible)
    }

    func present(preferences: AppPreferences, status: String) {
        let opening = window?.isVisible != true
        if opening {
            nameField.stringValue = preferences.receiverName
            askToSaveButton.state = preferences.automaticSave ? .off : .on
            automaticSaveButton.state = preferences.automaticSave ? .on : .off
            destination = preferences.destination
            avatarPNG = preferences.avatarPNG
            refreshAvatar()
            soundButton.state = preferences.completionSound ? .on : .off
            updateNotificationsButton.state = preferences.updateNotifications ? .on : .off
            languageMenu.selectItem(at: languageChoices.firstIndex(of: preferences.language) ?? 0)
            loginItemDraft = nil
            loginItemError = nil
            hasUnsavedChanges = false
            refreshFolder()
            saveButton.isEnabled = true
            setStatus(status)
        }
        refreshLoginItem()
        if opening, let window { WindowPlacement.center(window) }
        if opening { scrollView.documentView?.scroll(.zero) }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if opening { window?.makeFirstResponder(nil) }
    }

    func setStatus(_ text: String, error: Bool = false) {
        feedback.stringValue = text
        feedback.textColor = error ? .systemRed : .secondaryLabelColor
        feedback.toolTip = text
        feedback.isHidden = text.isEmpty
        resizeToFit()
    }

    func setSavedStatus(_ text: String, error: Bool = false) {
        guard !hasUnsavedChanges else { return }
        setStatus(text, error: error)
    }

    func refreshDestination(from old: SaveDestination, to updated: SaveDestination) {
        guard destination == old else { return }  // Preserve a newly selected, unsaved draft.
        destination = updated
        refreshFolder()
    }

    private func refreshFolder() {
        folderLabel.stringValue = destination?.displayPath ?? L10n.text("No folder selected", "Nie wybrano folderu")
        folderLabel.toolTip = destination?.displayPath
        let automatic = automaticSaveButton.state == .on
        folderRow.isHidden = !automatic
        chooseButton.isEnabled = automatic && !isChoosingFile
        folderLabel.textColor = automatic ? .labelColor : .tertiaryLabelColor
        resizeToFit()
    }

    @objc private func changed() { hasUnsavedChanges = true; saveButton.isEnabled = true; setStatus("") }
    @objc private func loginItemChanged() {
        loginItemDraft = loginItemButton.state == .on
        loginItemError = nil
        changed()
        refreshLoginItem()
    }
    @objc private func openLoginItemSettings() { loginItems.openSettings() }

    func windowDidBecomeKey(_ notification: Notification) { refreshLoginItem() }
    func windowDidChangeScreen(_ notification: Notification) { resizeToFit() }

    private func refreshLoginItem() {
        let status = loginItems.status()
        loginItemButton.state = (loginItemDraft ?? (status == .enabled)) ? .on : .off
        loginItemSettingsButton.isHidden = status != .requiresApproval
        loginItemStatus.textColor = loginItemError == nil ? .secondaryLabelColor : .systemRed
        if let loginItemError {
            loginItemStatus.stringValue = L10n.format("Could not change launch at login: %@", "Nie udało się zmienić autostartu: %@", loginItemError.localizedDescription)
        } else if status == .requiresApproval {
            loginItemStatus.stringValue = L10n.text("Launch at login is disabled in macOS. Enable AimDrop in System Settings.", "Autostart jest wyłączony w macOS. Włącz AimDrop w ustawieniach systemowych.")
        } else {
            switch status {
            case .enabled, .notRegistered, .notFound:
                // mainApp can return notFound before its first registration.
                loginItemStatus.stringValue = ""
            default:
                loginItemStatus.stringValue = L10n.text("Could not read the macOS login item status.", "Nie można odczytać stanu autostartu w macOS.")
            }
        }
        loginItemStatus.isHidden = loginItemStatus.stringValue.isEmpty
        loginItemStatus.toolTip = loginItemStatus.stringValue
        resizeToFit()
    }
    func controlTextDidChange(_ notification: Notification) { changed() }
    @objc private func modeChanged(_ sender: NSButton) {
        automaticSaveButton.state = sender === automaticSaveButton ? .on : .off
        askToSaveButton.state = sender === askToSaveButton ? .on : .off
        refreshFolder()
        changed()
    }

    @objc private func chooseFolder() {
        guard let window = window, !isChoosingFile else { return }
        guard canChooseFile?() != false else {
            setStatus(L10n.text("Close the current transfer window first.", "Najpierw zamknij bieżące okno odbioru."), error: true)
            return
        }
        let picker = NSOpenPanel()
        picker.title = L10n.text("Automatic save folder", "Folder automatycznego zapisu")
        picker.prompt = L10n.text("Choose folder", "Wybierz folder")
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        self.picker = picker
        isChoosingFile = true
        saveButton.isEnabled = false
        refreshFolder()
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            if response == .OK, let url = picker.url {
                do { self.destination = try SaveDestination(url: url); self.changed() }
                catch { self.setStatus(error.localizedDescription, error: true) }
            }
            self.finishPicker()
        }
    }

    private func refreshAvatar() {
        avatarPreview.image = avatarPNG.flatMap { NSImage(data: $0) }
            ?? Bundle.main.url(forResource: "AimDropAvatar", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
            ?? AimDropArtwork.applicationIcon
        resetAvatarButton.isEnabled = avatarPNG != nil && !isChoosingFile
        avatarButton.isEnabled = !isChoosingFile
    }
    private func finishPicker() {
        picker = nil; cropController = nil
        isChoosingFile = false; saveButton.isEnabled = true
        refreshFolder(); refreshAvatar()
        onPickerClosed?()
    }
    @objc private func resetAvatar() {
        guard !isChoosingFile else { return }
        avatarPNG = nil; refreshAvatar(); changed()
    }
    @objc private func chooseAvatar() {
        guard let window, !isChoosingFile else { return }
        guard canChooseFile?() != false else { setStatus(L10n.text("Close the current transfer window first.", "Najpierw zamknij bieżące okno odbioru."), error: true); return }
        let picker = NSOpenPanel()
        picker.title = L10n.text("Choose an avatar image", "Wybierz obraz awatara")
        picker.prompt = L10n.text("Adjust…", "Dopasuj…")
        picker.allowedContentTypes = [.image]
        picker.canChooseDirectories = false; picker.canChooseFiles = true; picker.allowsMultipleSelection = false
        self.picker = picker
        isChoosingFile = true; saveButton.isEnabled = false
        refreshFolder(); refreshAvatar()
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = picker.url else { self.finishPicker(); return }
            self.picker = nil
            self.setStatus(L10n.text("Preparing image…", "Przygotowywanie zdjęcia…"))
            self.imageQueue.async { [weak self] in
                let result = Result { try ReceiverAvatar.source(at: url) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window else { return }
                    switch result {
                    case .success(let image):
                        let controller = AvatarCropWindowController(image: image)
                        self.cropController = controller
                        self.setStatus("")
                        controller.present(on: window) { [weak self] avatar in
                            guard let self else { return }
                            if let avatar { self.avatarPNG = avatar.png; self.changed() }
                            self.finishPicker()
                        }
                    case .failure(let error):
                        self.setStatus(error.localizedDescription, error: true)
                        self.finishPicker()
                    }
                }
            }
        }
    }

    @objc private func save() {
        guard !isChoosingFile else { return }
        do {
            let preferences = try AppPreferences(receiverName: nameField.stringValue,
                                                  automaticSave: automaticSaveButton.state == .on,
                                                  destination: destination,
                                                  completionSound: soundButton.state == .on,
                                                  avatarPNG: avatarPNG,
                                                  language: languageChoices[max(0, languageMenu.indexOfSelectedItem)],
                                                  updateNotifications: updateNotificationsButton.state == .on).validated()
            nameField.stringValue = preferences.receiverName
            hasUnsavedChanges = false
            saveButton.isEnabled = false
            guard onSave?(preferences) != false else {
                hasUnsavedChanges = true; saveButton.isEnabled = true
                return
            }
            // Only an explicitly edited checkbox may change the OS setting.
            // Saving other preferences must not undo a change in System Settings.
            if let enabled = loginItemDraft {
                do {
                    try loginItems.setEnabled(enabled)
                    loginItemDraft = nil
                    loginItemError = nil
                } catch {
                    loginItemError = error
                    hasUnsavedChanges = true; saveButton.isEnabled = true
                }
            }
            refreshLoginItem()
        } catch { setStatus(error.localizedDescription, error: true) }
    }

    @objc private func closeSettings() { if !isChoosingFile { close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isChoosingFile }
}

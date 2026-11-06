import Cocoa
import UniformTypeIdentifiers
import ServiceManagement

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let nameField = NSTextField(string: "")
    private let saveMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languageMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languageChoices = AppLanguage.allCases
    private let nameLabel = NSTextField(labelWithString: "")
    private let nameHint = NSTextField(wrappingLabelWithString: "")
    private let saveLabel = NSTextField(labelWithString: "")
    private let folderHint = NSTextField(wrappingLabelWithString: "")
    private let languageLabel = NSTextField(labelWithString: "")
    private let updatesHint = NSTextField(wrappingLabelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let updatesButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private var checkingForUpdates = false
    private var contentStack: NSStackView?
    private var footerStack: NSStackView?
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
    var onCheckForUpdates: (() -> Void)?

    init(loginItems: LoginItemManager = .system) {
        self.loginItems = loginItems
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        contentStack = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
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
        nameField.font = .systemFont(ofSize: 17, weight: .medium)
        nameField.identifier = NSUserInterfaceItemIdentifier("receiverName")
        let avatarText = NSStackView(views: [nameLabel, nameField, avatarButtons])
        avatarText.orientation = .vertical; avatarText.alignment = .leading; avatarText.spacing = 8
        let avatarRow = NSStackView(views: [avatarPreview, avatarText]); avatarRow.spacing = 20; avatarRow.alignment = .centerY
        stack.addArrangedSubview(avatarRow)
        avatarRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        avatarText.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -108).isActive = true
        nameField.widthAnchor.constraint(equalTo: avatarText.widthAnchor).isActive = true
        avatarPreview.widthAnchor.constraint(equalToConstant: 88).isActive = true
        avatarPreview.heightAnchor.constraint(equalToConstant: 88).isActive = true
        stack.setCustomSpacing(10, after: avatarRow)
        styleHint(nameHint)
        stack.addArrangedSubview(nameHint)
        nameHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        addDivider(to: stack)

        saveLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(saveLabel)
        stack.setCustomSpacing(6, after: saveLabel)
        saveMode.target = self
        saveMode.action = #selector(modeChanged)
        stack.addArrangedSubview(saveMode)
        saveMode.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.maximumNumberOfLines = 1
        folderLabel.font = .systemFont(ofSize: 12)
        chooseButton.target = self
        chooseButton.action = #selector(chooseFolder)
        chooseButton.bezelStyle = .rounded
        let row = NSStackView(views: [folderLabel, chooseButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chooseButton.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        styleHint(folderHint)
        stack.addArrangedSubview(folderHint)
        folderHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        soundButton.target = self
        soundButton.action = #selector(changed)
        stack.addArrangedSubview(soundButton)
        addDivider(to: stack)

        languageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        languageMenu.target = self
        languageMenu.action = #selector(changed)
        languageMenu.identifier = NSUserInterfaceItemIdentifier("appLanguage")
        let languageRow = NSStackView(views: [languageLabel, languageMenu])
        languageRow.spacing = 20
        languageRow.alignment = .centerY
        stack.addArrangedSubview(languageRow)
        languageRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        languageLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true
        languageMenu.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -120).isActive = true
        languageMenu.setContentHuggingPriority(.defaultLow, for: .horizontal)

        loginItemButton.target = self
        loginItemButton.action = #selector(loginItemChanged)
        loginItemButton.identifier = NSUserInterfaceItemIdentifier("launchAtLogin")
        loginItemSettingsButton.target = self
        loginItemSettingsButton.action = #selector(openLoginItemSettings)
        loginItemSettingsButton.bezelStyle = .rounded
        loginItemSettingsButton.controlSize = .small
        loginItemSettingsButton.font = .systemFont(ofSize: 11)
        loginItemSettingsButton.isHidden = true
        let loginRow = NSStackView(views: [loginItemButton, loginItemSettingsButton])
        loginRow.spacing = 16
        loginRow.alignment = .centerY
        stack.addArrangedSubview(loginRow)
        stack.setCustomSpacing(6, after: loginRow)
        loginItemStatus.font = .systemFont(ofSize: 11)
        loginItemStatus.maximumNumberOfLines = 3
        loginItemStatus.lineBreakMode = .byTruncatingTail
        loginItemStatus.identifier = NSUserInterfaceItemIdentifier("loginItemStatus")
        stack.addArrangedSubview(loginItemStatus)
        loginItemStatus.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        versionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        updatesButton.target = self
        updatesButton.action = #selector(checkForUpdates)
        updatesButton.identifier = NSUserInterfaceItemIdentifier("checkForUpdates")
        updatesButton.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let updateRow = NSStackView(views: [versionLabel, spacer, updatesButton])
        updateRow.alignment = .centerY
        stack.addArrangedSubview(updateRow)
        updateRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(4, after: updateRow)
        styleHint(updatesHint)
        stack.addArrangedSubview(updatesHint)
        updatesHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        feedback.maximumNumberOfLines = 3
        feedback.lineBreakMode = .byTruncatingTail
        feedback.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(feedback)
        closeButton.target = self
        closeButton.action = #selector(closeSettings)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        let buttons = NSStackView(views: [closeButton, saveButton])
        footerStack = buttons
        buttons.spacing = 8
        buttons.setHuggingPriority(.required, for: .horizontal)
        closeButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        saveButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        feedback.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -20),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            feedback.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            feedback.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -16),
            feedback.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            feedback.heightAnchor.constraint(lessThanOrEqualToConstant: 48),
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
        relocalize()
    }

    private func addDivider(to stack: NSStackView) {
        let divider = NSBox()
        divider.boxType = .separator
        stack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(16, after: divider)
    }

    private func styleHint(_ view: NSTextField) {
        view.font = .systemFont(ofSize: 11)
        view.textColor = .secondaryLabelColor
    }

    func relocalize() {
        window?.title = L10n.text("AimDrop Settings", "Ustawienia AimDrop")
        nameLabel.stringValue = L10n.text("AirDrop name", "Nazwa w AirDrop")
        nameField.setAccessibilityLabel(L10n.text("AirDrop receiver name", "Nazwa widoczna w AirDrop"))
        avatarPreview.setAccessibilityLabel(L10n.text("iPhone receiver avatar", "Awatar widoczny na iPhonie"))
        avatarButton.title = L10n.text("Choose image…", "Wybierz zdjęcie…")
        resetAvatarButton.title = L10n.text("Reset logo", "Przywróć logo")
        nameHint.stringValue = L10n.text("A new name or avatar requires a new PIN. Reopen AirDrop on your iPhone after pairing.", "Zmiana nazwy lub awatara wymaga nowego PIN-u. Po sparowaniu otwórz ponownie AirDrop na iPhonie.")
        saveLabel.stringValue = L10n.text("Save received files", "Zapisywanie odebranych plików")
        let mode = max(0, saveMode.indexOfSelectedItem)
        saveMode.removeAllItems()
        saveMode.addItems(withTitles: [L10n.text("Ask for a folder after each transfer", "Pytaj o folder po każdym odbiorze"),
                                      L10n.text("Automatically save to a folder", "Automatycznie do wybranego folderu")])
        saveMode.selectItem(at: mode)
        saveMode.setAccessibilityLabel(L10n.text("Save mode", "Sposób zapisywania plików"))
        chooseButton.title = L10n.text("Choose…", "Wybierz…")
        folderHint.stringValue = L10n.text("Files you haven't saved stay in the inbox.", "Pliki oczekujące na zapis pozostają w buforze.")
        soundButton.title = L10n.text("Play a sound after saving", "Dźwięk po zapisaniu plików")
        loginItemButton.title = L10n.text("Launch at login", "Uruchamiaj przy logowaniu")
        loginItemSettingsButton.title = L10n.text("macOS Settings…", "Ustawienia macOS…")
        languageLabel.stringValue = L10n.text("Language", "Język")
        let selectedLanguage = max(0, languageMenu.indexOfSelectedItem)
        languageMenu.removeAllItems()
        languageMenu.addItems(withTitles: languageChoices.map(\.nativeName))
        languageMenu.selectItem(at: selectedLanguage)
        languageMenu.setAccessibilityLabel(L10n.text("Application language", "Język aplikacji"))
        versionLabel.stringValue = L10n.format("Version %@", "Wersja %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.8.0")
        updatesHint.stringValue = L10n.text("Automatically checks GitHub for updates every 24 hours.", "Automatycznie sprawdza aktualizacje na GitHubie co 24 godziny.")
        closeButton.title = L10n.text("Close", "Zamknij")
        saveButton.title = L10n.text("Save", "Zapisz")
        setCheckingForUpdates(checkingForUpdates)
        refreshFolder()
        refreshLoginItem()
    }

    private func resizeToFit() {
        guard let window, let content = window.contentView, let contentStack, let footerStack else { return }
        content.layoutSubtreeIfNeeded()
        let height = max(500, ceil(contentStack.fittingSize.height + footerStack.fittingSize.height + 68))
        guard abs(content.bounds.height - height) > 1 else { return }
        let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 600, height: height))
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height,
                               width: frame.width, height: frame.height), display: window.isVisible)
    }

    func setCheckingForUpdates(_ checking: Bool) {
        checkingForUpdates = checking
        updatesButton.title = checking ? L10n.text("Checking…", "Sprawdzanie…") : L10n.text("Check for Updates…", "Sprawdź aktualizacje…")
        updatesButton.isEnabled = !checking
    }

    @objc private func checkForUpdates() { onCheckForUpdates?() }

    func present(preferences: AppPreferences, status: String) {
        if window?.isVisible != true {
            nameField.stringValue = preferences.receiverName
            saveMode.selectItem(at: preferences.automaticSave ? 1 : 0)
            destination = preferences.destination
            avatarPNG = preferences.avatarPNG
            refreshAvatar()
            soundButton.state = preferences.completionSound ? .on : .off
            languageMenu.selectItem(at: languageChoices.firstIndex(of: preferences.language) ?? 0)
            loginItemDraft = nil
            loginItemError = nil
            hasUnsavedChanges = false
            refreshFolder()
            saveButton.isEnabled = true
            setStatus(status)
        }
        refreshLoginItem()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func setStatus(_ text: String, error: Bool = false) {
        feedback.stringValue = text
        feedback.textColor = error ? .systemRed : .secondaryLabelColor
        feedback.toolTip = text
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
        let automatic = saveMode.indexOfSelectedItem == 1
        chooseButton.isEnabled = automatic && !isChoosingFile
        folderLabel.textColor = automatic ? .labelColor : .tertiaryLabelColor
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
    @objc private func modeChanged() { refreshFolder(); changed() }

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
                                                  automaticSave: saveMode.indexOfSelectedItem == 1,
                                                  destination: destination,
                                                  completionSound: soundButton.state == .on,
                                                  avatarPNG: avatarPNG,
                                                  language: languageChoices[max(0, languageMenu.indexOfSelectedItem)]).validated()
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

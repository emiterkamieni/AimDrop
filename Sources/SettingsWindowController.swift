import Cocoa
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let nameField = NSTextField(string: "")
    private let saveMode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let folderLabel = NSTextField(labelWithString: "Nie wybrano folderu")
    private let chooseButton = NSButton(title: "Wybierz…", target: nil, action: nil)
    private let soundButton = NSButton(checkboxWithTitle: "Dźwięk po zapisaniu plików", target: nil, action: nil)
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

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Ustawienia AirFolder"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
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

        let heading = NSTextField(labelWithString: "Odbieranie przez AirDrop")
        heading.font = .systemFont(ofSize: 21, weight: .semibold)
        stack.addArrangedSubview(heading)
        stack.setCustomSpacing(22, after: heading)

        avatarButton.target = self; avatarButton.action = #selector(chooseAvatar)
        resetAvatarButton.target = self; resetAvatarButton.action = #selector(resetAvatar)
        avatarButton.bezelStyle = .rounded; resetAvatarButton.bezelStyle = .rounded
        avatarPreview.setAccessibilityElement(true)
        avatarPreview.setAccessibilityRole(.image)
        avatarPreview.setAccessibilityLabel("Awatar widoczny na iPhonie")
        avatarPreview.identifier = NSUserInterfaceItemIdentifier("avatarPreview")
        let avatarButtons = NSStackView(views: [avatarButton, resetAvatarButton]); avatarButtons.spacing = 8
        let avatarText = NSStackView(views: [label("Awatar w AirDrop"), hint("Tak będzie wyglądać odbiornik na iPhonie."), avatarButtons])
        avatarText.orientation = .vertical; avatarText.alignment = .leading; avatarText.spacing = 8
        let avatarRow = NSStackView(views: [avatarPreview, avatarText]); avatarRow.spacing = 20; avatarRow.alignment = .centerY
        stack.addArrangedSubview(avatarRow)
        avatarPreview.widthAnchor.constraint(equalToConstant: 88).isActive = true
        avatarPreview.heightAnchor.constraint(equalToConstant: 88).isActive = true
        stack.setCustomSpacing(20, after: avatarRow)

        let nameLabel = label("Nazwa widoczna w AirDrop")
        stack.addArrangedSubview(nameLabel)
        stack.setCustomSpacing(6, after: nameLabel)
        nameField.placeholderString = "AirFolder"
        nameField.delegate = self
        nameField.setAccessibilityLabel("Nazwa widoczna w AirDrop")
        nameField.identifier = NSUserInterfaceItemIdentifier("receiverName")
        stack.addArrangedSubview(nameField)
        nameField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let nameHint = hint("Zmiana nazwy lub awatara wymaga nowego PIN-u. Po sparowaniu otwórz ponownie AirDrop na iPhonie, aby odświeżyć obraz. Restart aplikacji zachowuje parowanie.")
        stack.addArrangedSubview(nameHint)
        nameHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(20, after: nameHint)

        let saveLabel = label("Zapisywanie nowych plików")
        stack.addArrangedSubview(saveLabel)
        stack.setCustomSpacing(6, after: saveLabel)
        saveMode.addItems(withTitles: ["Pytaj o folder po każdym odbiorze", "Automatycznie do wybranego folderu"])
        saveMode.target = self
        saveMode.action = #selector(modeChanged)
        saveMode.setAccessibilityLabel("Sposób zapisywania plików")
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
        let folderHint = hint("Pliki oczekujące na zapis pozostają do ręcznego zapisania.")
        stack.addArrangedSubview(folderHint)
        stack.setCustomSpacing(18, after: folderHint)

        soundButton.target = self
        soundButton.action = #selector(changed)
        stack.addArrangedSubview(soundButton)

        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        feedback.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(feedback)
        let close = NSButton(title: "Zamknij", target: self, action: #selector(closeSettings))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        let buttons = NSStackView(views: [close, saveButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            buttons.widthAnchor.constraint(equalToConstant: 168),
            close.widthAnchor.constraint(equalToConstant: 80),
            feedback.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            feedback.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -16),
            feedback.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            feedback.heightAnchor.constraint(lessThanOrEqualToConstant: 48),
            saveButton.widthAnchor.constraint(equalToConstant: 80)
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let view = NSTextField(labelWithString: text)
        view.font = .systemFont(ofSize: 13, weight: .semibold)
        return view
    }

    private func hint(_ text: String) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = .systemFont(ofSize: 11)
        view.textColor = .secondaryLabelColor
        return view
    }

    func present(preferences: AppPreferences, status: String) {
        if window?.isVisible != true {
            nameField.stringValue = preferences.receiverName
            saveMode.selectItem(at: preferences.automaticSave ? 1 : 0)
            destination = preferences.destination
            avatarPNG = preferences.avatarPNG
            refreshAvatar()
            soundButton.state = preferences.completionSound ? .on : .off
            hasUnsavedChanges = false
            refreshFolder()
            saveButton.isEnabled = true
            setStatus(status)
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func setStatus(_ text: String, error: Bool = false) {
        feedback.stringValue = text
        feedback.textColor = error ? .systemRed : .secondaryLabelColor
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
        folderLabel.stringValue = destination?.displayPath ?? "Nie wybrano folderu"
        folderLabel.toolTip = destination?.displayPath
        let automatic = saveMode.indexOfSelectedItem == 1
        chooseButton.isEnabled = automatic && !isChoosingFile
        folderLabel.textColor = automatic ? .labelColor : .tertiaryLabelColor
    }

    @objc private func changed() { hasUnsavedChanges = true; saveButton.isEnabled = true; setStatus("") }
    func controlTextDidChange(_ notification: Notification) { changed() }
    @objc private func modeChanged() { refreshFolder(); changed() }

    @objc private func chooseFolder() {
        guard let window = window, !isChoosingFile else { return }
        guard canChooseFile?() != false else {
            setStatus("Najpierw zamknij bieżące okno odbioru.", error: true)
            return
        }
        let picker = NSOpenPanel()
        picker.title = "Folder automatycznego zapisu"
        picker.prompt = "Wybierz folder"
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
            ?? Bundle.main.url(forResource: "AirFolder", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
            ?? AirFolderArtwork.applicationIcon
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
        guard canChooseFile?() != false else { setStatus("Najpierw zamknij bieżące okno odbioru.", error: true); return }
        let picker = NSOpenPanel()
        picker.title = "Wybierz obraz awatara"
        picker.prompt = "Dopasuj…"
        picker.allowedContentTypes = [.image]
        picker.canChooseDirectories = false; picker.canChooseFiles = true; picker.allowsMultipleSelection = false
        self.picker = picker
        isChoosingFile = true; saveButton.isEnabled = false
        refreshFolder(); refreshAvatar()
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = picker.url else { self.finishPicker(); return }
            self.picker = nil
            self.setStatus("Przygotowywanie zdjęcia…")
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
                                                  avatarPNG: avatarPNG).validated()
            nameField.stringValue = preferences.receiverName
            hasUnsavedChanges = false
            saveButton.isEnabled = false
            if onSave?(preferences) == false { hasUnsavedChanges = true; saveButton.isEnabled = true }
        } catch { setStatus(error.localizedDescription, error: true) }
    }

    @objc private func closeSettings() { if !isChoosingFile { close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isChoosingFile }
}

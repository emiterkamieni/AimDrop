import Cocoa

struct PendingTransfer {
    let id: String
    let files: [String]
    let paths: [String]
    let received: Date?
    let expires: Date?

    init?(_ event: [String: Any]) {
        guard let id = event["id"] as? String else { return nil }
        self.id = id
        files = event["files"] as? [String] ?? []
        paths = event["paths"] as? [String] ?? []
        received = (event["received_at_ns"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1e9) }
        expires = (event["expires_at_ns"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1e9) }
    }

    static func items(_ count: Int) -> String {
        L10n.plural("items", count: count, count == 1 ? "%ld item" : "%ld items",
                    count == 1 ? "%ld element" : "%ld elementów", count)
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate(Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date()) ? "dMMMHHmm" : "dMMMyHHmm")
        return formatter.string(from: date)
    }
}

private final class PendingFileRowView: NSView {
    private let label: NSTextField
    private let onEnter: (NSView) -> Void
    private let onExit: (NSView) -> Void
    private var tracking: NSTrackingArea?
    private var hovered = false

    init(title: String, onEnter: @escaping (NSView) -> Void, onExit: @escaping (NSView) -> Void) {
        label = NSTextField(labelWithString: title)
        self.onEnter = onEnter; self.onExit = onExit
        super.init(frame: NSRect(x: 0, y: 0, width: 224, height: 24))
        autoresizingMask = [.width]
        label.font = .menuFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.textColor = .labelColor
        frame.size.width = max(224, min(380, label.fittingSize.width + 28))
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    func beginHover() { hovered = true; needsDisplay = true; onEnter(self) }
    override func mouseEntered(with event: NSEvent) { beginHover() }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true; onExit(self) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hovered = false; onExit(self) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if hovered {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
    }
}

private final class PendingTransferActionsView: NSView {
    let saveButton: NSButton
    let deleteButton: NSButton
    private let onSave: () -> Void
    private let onDelete: () -> Void

    init(enabled: Bool, onSave: @escaping () -> Void, onDelete: @escaping () -> Void) {
        saveButton = NSButton(title: L10n.text("Save", "Zapisz"), target: nil, action: nil)
        deleteButton = NSButton(title: L10n.text("Delete", "Usuń"), target: nil, action: nil)
        self.onSave = onSave
        self.onDelete = onDelete
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
        autoresizingMask = [.width]

        for button in [saveButton, deleteButton] {
            ActionButtonStyle.apply(to: button)
            button.isEnabled = enabled
            button.target = self
            addSubview(button)
        }
        saveButton.bezelColor = .controlAccentColor
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center
        saveButton.attributedTitle = NSAttributedString(string: saveButton.title, attributes: [
            .font: ActionButtonStyle.font,
            .foregroundColor: enabled ? NSColor.white : NSColor.disabledControlTextColor,
            .paragraphStyle: titleStyle
        ])
        saveButton.identifier = NSUserInterfaceItemIdentifier("savePendingTransfer")
        deleteButton.identifier = NSUserInterfaceItemIdentifier("deletePendingTransfer")
        saveButton.action = #selector(save)
        deleteButton.action = #selector(delete)

        let buttonWidth = max(ActionButtonStyle.minimumWidth, max(saveButton.fittingSize.width, deleteButton.fittingSize.width))
        frame.size.width = buttonWidth * 2 + 32
        NSLayoutConstraint.activate([
            saveButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            deleteButton.leadingAnchor.constraint(equalTo: saveButton.trailingAnchor, constant: 8),
            saveButton.widthAnchor.constraint(equalTo: deleteButton.widthAnchor),
            saveButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func save() { perform(onSave) }
    @objc private func delete() { perform(onDelete) }

    private func perform(_ action: @escaping () -> Void) {
        // Close the whole menu chain before bringing up the folder picker or
        // confirmation. Keep the action alive after AppKit removes this view.
        var menu = enclosingMenuItem?.menu
        while let parent = menu?.supermenu { menu = parent }
        menu?.cancelTracking()
        DispatchQueue.main.async(execute: action)
    }
}

private final class PendingDeleteAllView: NSView {
    private let onDelete: () -> Void

    init(enabled: Bool, onDelete: @escaping () -> Void) {
        self.onDelete = onDelete
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
        autoresizingMask = [.width]
        let button = NSButton(title: L10n.text("Delete All", "Usuń wszystkie"), target: self, action: #selector(deleteAll))
        ActionButtonStyle.apply(to: button)
        button.isEnabled = enabled
        button.identifier = NSUserInterfaceItemIdentifier("deleteAllPendingTransfers")
        frame.size.width = max(240, button.fittingSize.width + 24)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func deleteAll() {
        var menu = enclosingMenuItem?.menu
        while let parent = menu?.supermenu { menu = parent }
        menu?.cancelTracking()
        DispatchQueue.main.async(execute: onDelete)
    }
}

final class PendingTransfersMenu: NSObject, NSMenuDelegate {
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var onSave: ((String) -> Void)?
    var onTrash: ((String) -> Void)?
    var onTrashAll: (([String]) -> Void)?
    var canAct: ((String) -> Bool)?
    private var receipts: [PendingTransfer] = []
    private var saving = Set<String>()
    private var trashing = Set<String>()
    private var automaticTrash = true
    private let preview = PendingFilePreviewController()

    override init() {
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.submenu = menu
    }

    func update(_ events: [[String: Any]], saving: Set<String>, trashing: Set<String>, automaticTrash: Bool) {
        receipts = events.compactMap(PendingTransfer.init).sorted {
            let left = $0.received ?? .distantPast, right = $1.received ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
        self.saving = saving; self.trashing = trashing; self.automaticTrash = automaticTrash
        if let id = preview.transferID, saving.contains(id) || trashing.contains(id) || !receipts.contains(where: { $0.id == id }) {
            preview.hide()
        }
        item.title = L10n.format("Unsaved transfers (%ld)", "Niezapisane transfery (%ld)", receipts.count)
        // Rebuild on opening rather than replacing a submenu under the pointer.
    }

    func menuNeedsUpdate(_ menu: NSMenu) { if menu === item.submenu { rebuild() } }
    func menuDidClose(_ menu: NSMenu) { if menu === item.submenu { preview.hide() } }
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        if let row = item?.view as? PendingFileRowView { row.beginHover() }
        else if item != nil { preview.hide() }
    }
    func hidePreview() { preview.hide() }

    func rebuild() {
        guard let menu = item.submenu else { return }
        preview.hide()
        menu.removeAllItems()
        if receipts.isEmpty {
            label(L10n.text("No unsaved transfers", "Brak niezapisanych transferów"), in: menu)
        }
        for receipt in receipts {
            let title = PendingTransfer.items(receipt.files.count) + receipt.received.map { " — " + PendingTransfer.date($0) }.orEmpty
            let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            row.representedObject = receipt.id
            let details = NSMenu()
            details.autoenablesItems = false
            details.delegate = self
            for (index, name) in receipt.files.prefix(10).enumerated() {
                let singleLine = name.components(separatedBy: .newlines).joined(separator: " ")
                let entry = label(singleLine.count > 64 ? String(singleLine.prefix(61)) + "…" : singleLine, in: details)
                entry.toolTip = name
                if receipt.paths.indices.contains(index) {
                    let url = URL(fileURLWithPath: receipt.paths[index])
                    if PendingFilePreviewLoader.extensions.contains(url.pathExtension.lowercased()) {
                        entry.toolTip = nil
                        entry.isEnabled = true
                        entry.view = PendingFileRowView(title: singleLine, onEnter: { [weak self] anchor in
                            guard let self, !self.saving.contains(receipt.id), !self.trashing.contains(receipt.id),
                                  self.canAct?(receipt.id) != false else { return }
                            self.preview.schedule(url: url, transferID: receipt.id, anchor: anchor)
                        }, onExit: { [weak self] anchor in self?.preview.hide(for: anchor) })
                    }
                }
            }
            if receipt.files.count > 10 {
                label(L10n.format("…and %@ more", "…i jeszcze %@", PendingTransfer.items(receipt.files.count - 10)), in: details)
            }
            details.addItem(.separator())
            let busy = saving.contains(receipt.id) || trashing.contains(receipt.id)
            let enabled = !busy && canAct?(receipt.id) != false
            let actions = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            actions.representedObject = receipt.id
            actions.view = PendingTransferActionsView(enabled: enabled, onSave: { [weak self] in
                guard let self, self.canAct?(receipt.id) != false else { return }
                self.onSave?(receipt.id)
            }, onDelete: { [weak self] in
                guard let self, self.canAct?(receipt.id) != false else { return }
                self.onTrash?(receipt.id)
            })
            details.addItem(actions)
            details.addItem(.separator())
            if saving.contains(receipt.id) {
                label(L10n.text("Saving…", "Zapisywanie…"), in: details)
            } else if trashing.contains(receipt.id) {
                label(L10n.text("Moving to Trash…", "Przenoszenie do Kosza…"), in: details)
            } else if !automaticTrash {
                label(L10n.text("Automatic deletion is off", "Automatyczne usuwanie wyłączone"), in: details)
            } else if let expires = receipt.expires {
                let date = PendingTransfer.date(expires)
                label(receipt.files.count == 1
                      ? L10n.format("Item available until %@", "Dostępny do %@", date)
                      : L10n.format("Items available until %@", "Dostępne do %@", date), in: details)
            }
            row.submenu = details
            menu.addItem(row)
        }
        if !receipts.isEmpty {
            menu.addItem(.separator())
            let deleteAll = NSMenuItem(title: L10n.text("Delete All", "Usuń wszystkie"), action: nil, keyEquivalent: "")
            let displayedIDs = receipts.map(\.id)
            deleteAll.view = PendingDeleteAllView(enabled: receipts.contains { !saving.contains($0.id) && !trashing.contains($0.id) && canAct?($0.id) != false }) { [weak self] in
                self?.preview.hide()
                self?.onTrashAll?(displayedIDs)
            }
            menu.addItem(deleteAll)
        }
    }

    @discardableResult private func label(_ title: String, in menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        return item
    }

}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

import Cocoa

enum ActionButtonStyle {
    static let height: CGFloat = 28
    static let minimumWidth: CGFloat = 96
    static var font: NSFont { .systemFont(ofSize: 13, weight: .medium) }

    static func apply(to button: NSButton, autoLayout: Bool = true) {
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .flexiblePush
        button.controlSize = .regular
        button.font = font
        button.image = nil
        button.imagePosition = .noImage
        if autoLayout {
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: height),
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth)
            ])
        }
    }
}

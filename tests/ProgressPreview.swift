import Cocoa

@main
struct ProgressPreview {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard (2...3).contains(CommandLine.arguments.count) else { fatalError("Provide the output PNG path and optional completion flag") }
        try TransferProgressBanners.renderPreview(to: URL(fileURLWithPath: CommandLine.arguments[1]),
                                                 completion: CommandLine.arguments.last == "completion")
    }
}

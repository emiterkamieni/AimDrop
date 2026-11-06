import Cocoa

@main
struct ProgressResponsivenessChecks {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        let image = bitmap.cgImage!
        let banners = TransferProgressBanners(previewDecoder: { _ in
            precondition(!Thread.isMainThread, "Thumbnail decoding must never block AppKit")
            started.signal()
            precondition(release.wait(timeout: .now() + 3) == .success, "UI did not remain responsive")
            finished.signal()
            return image
        })
        var messages: [String] = []
        banners.log = { messages.append($0) }
        let id = UUID().uuidString
        let before = ProcessInfo.processInfo.systemUptime
        banners.incoming(["id": id, "files": ["responsiveness-test.png"], "preview": "held-by-test"])
        let elapsed = (ProcessInfo.processInfo.systemUptime - before) * 1000
        precondition(started.wait(timeout: .now() + 2) == .success)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        precondition(messages.contains { $0.contains("Progress card drawn") }, "Card must draw before its thumbnail is ready")
        precondition(messages.contains { $0.contains("visible=true") }, "Panel must be visible while thumbnail is blocked")
        banners.begin(id: id, progress: TransferProgress(event: ["bytes": 1, "total_bytes": 2]))
        banners.remove(id: id)
        release.signal()
        precondition(finished.wait(timeout: .now() + 2) == .success)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        precondition(!messages.contains { $0.contains("Preview decoded") }, "Discard a late thumbnail after cancel/removal")
        precondition(!NSApp.windows.contains { $0.isVisible }, "A late thumbnail must not resurrect the panel")
        print("PASS: panel drawn before blocked thumbnail, responsive progress, no resurrection after removal (presentation \(String(format: "%.1f", elapsed)) ms)")

        let target = TransferFileTarget(paths: ["/Example/Received/file (1).txt"], directory: "/Example/Received")
        var actions: [TransferFileAction] = []
        var cancellations = 0
        banners.onCancel = { _, _ in cancellations += 1 }
        banners.onFileAction = { action, received in
            precondition(received.paths == target.paths && received.directory == target.directory,
                         "Buttons must use final saved paths, including collision renames")
            actions.append(action)
        }
        for (index, action) in [TransferFileAction.reveal, .open].enumerated() {
            let id = UUID().uuidString
            banners.begin(id: id, progress: TransferProgress(event: ["phase": "saving"]))
            banners.finish(id: id)
            banners.completed(id: id, target: target, count: 1)
            if index == 0 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8)) }
            guard let panel = NSApp.windows.first(where: { $0.isVisible && $0.title == "AirFolder — pliki odebrane" }),
                  let view = panel.contentView else { fatalError("Old progress timer removed the completion panel") }
            let buttons = view.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            precondition(buttons.contains { $0.title == "Pokaż w Finderze" } && buttons.contains { $0.title == "Otwórz" },
                         "Both actions must be visible immediately")
            buttons.first { $0.title == (action == .reveal ? "Pokaż w Finderze" : "Otwórz") }!.performClick(nil)
            precondition(actions.last == action && !panel.isVisible, "Click must route the action and dismiss the card")
        }
        banners.completed(id: "dismiss-check", target: target, count: 1)
        let panel = NSApp.windows.first { $0.isVisible && $0.title == "AirFolder — pliki odebrane" }!
        let close = panel.contentView!.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "Zamknij powiadomienie" }!
        close.performClick(nil)
        precondition(cancellations == 0 && actions.count == 2 && !panel.isVisible,
                     "Closing a saved transfer must not cancel a network transfer or open files")
        print("PASS: completion survives progress timer, both direct buttons use saved paths, close only dismisses")
    }
}

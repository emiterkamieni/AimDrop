import Cocoa
import UserNotifications

final class TransferNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let queue = DispatchQueue(label: "pl.airfrajer.notifications")
    private let category = "AIRFRAJER_RECEIVED"
    private let revealAction = "REVEAL_FILES"
    private let openAction = "OPEN_FILES"
    private let pendingCategory = "AIRFRAJER_BUFFERED"
    private let saveAction = "SAVE_BUFFERED"
    private let updateCategory = "AIMDROP_UPDATE_AVAILABLE"
    private let downloadAction = "DOWNLOAD_UPDATE"
    private var deliveries: [String: Delivery] = [:]
    private var order: [String] = []
    private var delivering = false
    var log: ((String) -> Void)?
    var onSavePending: ((String) -> Void)?
    var onOpenUpdate: ((URL) -> Void)?

    private struct Delivery {
        let content: UNMutableNotificationContent?  // nil removes a destination reminder
        let completion: ((Bool) -> Void)?
    }

    func start() {
        center.delegate = self
        refreshCategories()
        requestPermission()
    }

    func refreshCategories() {
        // Keep actions for completion notifications delivered by older builds.
        let reveal = UNNotificationAction(identifier: revealAction, title: L10n.text("Show in Finder", "Pokaż w Finderze"), options: [.foreground])
        let open = UNNotificationAction(identifier: openAction, title: L10n.text("Open", "Otwórz"), options: [.foreground])
        let save = UNNotificationAction(identifier: saveAction, title: L10n.text("Choose folder", "Wybierz folder"), options: [.foreground])
        let download = UNNotificationAction(identifier: downloadAction, title: L10n.text("Download", "Pobierz"), options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [reveal, open], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: pendingCategory, actions: [save], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: updateCategory, actions: [download], intentIdentifiers: [], options: [])
        ])
    }

    private func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            guard let self = self else { return }
            self.queue.async {
                self.log?("Notification authorization: \(granted ? "granted" : "denied")")
                if let error = error { self.log?("Notification authorization error: \(error.localizedDescription)") }
            }
        }
    }

    private func identifier(_ id: String) -> String { "airfrajer.transfer." + id }

    func cancel(id: String) {
        queue.async {
            self.enqueue(id: self.identifier(id), content: nil)
        }
    }

    func awaitingDestination(id: String, count: Int) {
        queue.async {
            let content = UNMutableNotificationContent()
            // macOS owns the compact banner layout and overlays its action on
            // the right. Keep both lines short; the button supplies the prompt.
            content.title = L10n.text("Files received", "Pliki odebrane")
            content.body = L10n.format("%@ to save.", "%@ do zapisania.", TransferSummary.files(count))
            content.categoryIdentifier = self.pendingCategory
            content.threadIdentifier = "airfrajer.transfers"
            content.userInfo = ["pendingID": id]
            self.enqueue(id: self.identifier(id), content: content)
        }
    }

    func updateAvailable(version: String, url: URL, completion: @escaping (Bool) -> Void) {
        guard Self.isUpdateURL(url) else { completion(false); return }
        queue.async {
            let content = UNMutableNotificationContent()
            content.title = L10n.format("AimDrop %@", "AimDrop %@", version)
            content.body = L10n.text("Update available.", "Dostępna aktualizacja.")
            content.categoryIdentifier = self.updateCategory
            content.userInfo = ["updateURL": url.absoluteString]
            self.enqueue(id: "aimdrop.update.available", content: content, completion: completion)
        }
    }

    private static func isUpdateURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
            && url.port == nil && url.path.hasPrefix("/emiterkamieni/AimDrop/releases/")
    }

    // Serialize add/remove acknowledgements so a late destination reminder
    // cannot survive a successful save.
    private func enqueue(id: String, content: UNMutableNotificationContent?, completion: ((Bool) -> Void)? = nil) {
        if deliveries[id] == nil { order.append(id) }
        if let replaced = deliveries[id]?.completion { DispatchQueue.main.async { replaced(false) } }
        deliveries[id] = Delivery(content: content, completion: completion)
        deliverNext()
    }

    private func deliverNext() {
        guard !delivering, !order.isEmpty else { return }
        let id = order.removeFirst()
        guard let delivery = deliveries.removeValue(forKey: id) else { deliverNext(); return }
        guard let content = delivery.content else {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
            deliverNext()
            return
        }
        delivering = true
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    self.log?("Notification delivery failed: \(error.localizedDescription)")
                } else {
                    let kind = content.categoryIdentifier == self.pendingCategory ? "destination" : (content.categoryIdentifier == self.updateCategory ? "update" : "completion")
                    self.log?("Notification accepted by macOS: \(kind)")
                }
                if let completion = delivery.completion { DispatchQueue.main.async { completion(error == nil) } }
                self.delivering = false
                self.deliverNext()
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            defer { completionHandler() }
            if response.notification.request.content.categoryIdentifier == self.updateCategory {
                if response.actionIdentifier == self.downloadAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                   let value = info["updateURL"] as? String, let url = URL(string: value), Self.isUpdateURL(url) {
                    self.onOpenUpdate?(url)
                }
                return
            }
            if let id = info["pendingID"] as? String,
               response.actionIdentifier == self.saveAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                self.onSavePending?(id)
                return
            }
            let target = TransferFileTarget(paths: info["paths"] as? [String] ?? [], directory: info["directory"] as? String ?? "")
            if response.actionIdentifier == self.openAction {
                target.perform(.open)
            } else if response.actionIdentifier == self.revealAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                target.perform(.reveal)
            }
        }
    }
}

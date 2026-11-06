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
    private var deliveries: [String: Delivery] = [:]
    private var order: [String] = []
    private var delivering = false
    var log: ((String) -> Void)?
    var onSavePending: ((String) -> Void)?

    private struct Delivery {
        let content: UNMutableNotificationContent?  // nil removes a destination reminder
    }

    func start() {
        center.delegate = self
        // Keep actions for completion notifications delivered by older builds.
        let reveal = UNNotificationAction(identifier: revealAction, title: "Pokaż w Finderze", options: [.foreground])
        let open = UNNotificationAction(identifier: openAction, title: "Otwórz", options: [.foreground])
        let save = UNNotificationAction(identifier: saveAction, title: "Wybierz folder", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [reveal, open], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: pendingCategory, actions: [save], intentIdentifiers: [], options: [])
        ])
        requestPermission()
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
            content.title = "Pliki odebrane"
            content.body = "\(TransferSummary.noun(count, "plik", "pliki", "plików")) do zapisania."
            content.categoryIdentifier = self.pendingCategory
            content.threadIdentifier = "airfrajer.transfers"
            content.userInfo = ["pendingID": id]
            self.enqueue(id: self.identifier(id), content: content)
        }
    }

    // Serialize add/remove acknowledgements so a late destination reminder
    // cannot survive a successful save.
    private func enqueue(id: String, content: UNMutableNotificationContent?) {
        if deliveries[id] == nil { order.append(id) }
        deliveries[id] = Delivery(content: content)
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
                    self.log?("Notification accepted by macOS: \(content.categoryIdentifier == self.pendingCategory ? "destination" : "completion")")
                }
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

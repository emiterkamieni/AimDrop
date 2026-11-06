import Cocoa
import UserNotifications

final class TransferNotifications: NSObject, UNUserNotificationCenterDelegate {
    typealias Add = (UNNotificationRequest, @escaping (Error?) -> Void) -> Void

    private lazy var center = UNUserNotificationCenter.current()
    private let add: Add
    private let removePending: ([String]) -> Void
    private let removeDelivered: ([String]) -> Void
    private let queue = DispatchQueue(label: "pl.airfrajer.notifications")
    private let category = "AIRFRAJER_RECEIVED"
    private let revealAction = "REVEAL_FILES"
    private let openAction = "OPEN_FILES"
    private let pendingCategory = "AIRFRAJER_BUFFERED"
    private let saveAction = "SAVE_BUFFERED"
    private let updateCategory = "AIMDROP_UPDATE_AVAILABLE"
    private let updateIdentifier = "aimdrop.update.available"
    private let updateSession = UUID().uuidString
    private let downloadAction = "DOWNLOAD_UPDATE"
    // Policy, generations and delivery state are owned by queue.
    private var updateNotificationsEnabled = true
    private var updateGeneration: UInt64 = 0
    private var deliveries: [String: Delivery] = [:]
    private var order: [String] = []
    private var delivering = false
    var log: ((String) -> Void)?
    var onSavePending: ((String) -> Void)?
    var onOpenUpdate: ((URL) -> Void)?

    private struct Delivery {
        let content: UNMutableNotificationContent?  // nil removes a destination reminder
        let completion: ((Bool) -> Void)?
        let updateGeneration: UInt64?
    }

    init(add: Add? = nil, removePending: (([String]) -> Void)? = nil,
         removeDelivered: (([String]) -> Void)? = nil) {
        self.add = add ?? { request, completion in
            UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
        }
        self.removePending = removePending ?? { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: $0) }
        self.removeDelivered = removeDelivered ?? { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0) }
        super.init()
    }

    func setUpdateNotificationsEnabled(_ enabled: Bool) {
        queue.sync {
            self.updateNotificationsEnabled = enabled
            guard !enabled else { return }
            self.updateGeneration &+= 1
            if let rejected = self.deliveries.removeValue(forKey: self.updateIdentifier) {
                self.complete(rejected, accepted: false)
            }
            self.order.removeAll { $0 == self.updateIdentifier }
            // Do not wait for an in-flight add before removing an existing banner.
            self.removeNotification(id: self.updateIdentifier)
        }
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
        queue.async {
            guard self.updateNotificationsEnabled, Self.isUpdateURL(url) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = L10n.format("AimDrop %@", "AimDrop %@", version)
            content.body = L10n.text("Update available.", "Dostępna aktualizacja.")
            content.categoryIdentifier = self.updateCategory
            content.userInfo = ["updateURL": url.absoluteString, "updateSession": self.updateSession,
                                "updateGeneration": String(self.updateGeneration)]
            self.enqueue(id: self.updateIdentifier, content: content, completion: completion,
                         updateGeneration: self.updateGeneration)
        }
    }

    private static func isUpdateURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
            && url.port == nil && url.path.hasPrefix("/emiterkamieni/AimDrop/releases/")
    }

    // Serialize add/remove acknowledgements so a late destination reminder
    // cannot survive a successful save.
    private func enqueue(id: String, content: UNMutableNotificationContent?, completion: ((Bool) -> Void)? = nil,
                         updateGeneration: UInt64? = nil) {
        if deliveries[id] == nil { order.append(id) }
        if let replaced = deliveries[id] { complete(replaced, accepted: false) }
        deliveries[id] = Delivery(content: content, completion: completion, updateGeneration: updateGeneration)
        deliverNext()
    }

    private func isCurrent(_ delivery: Delivery) -> Bool {
        guard let generation = delivery.updateGeneration else { return true }
        return updateNotificationsEnabled && generation == updateGeneration
    }

    private func complete(_ delivery: Delivery, accepted: Bool) {
        guard let completion = delivery.completion else { return }
        DispatchQueue.main.async {
            // A preference change can overtake an acknowledgement already queued on main.
            let current = self.queue.sync { self.isCurrent(delivery) }
            completion(accepted && current)
        }
    }

    private func removeNotification(id: String) {
        removePending([id])
        removeDelivered([id])
    }

    private func deliverNext() {
        guard !delivering, !order.isEmpty else { return }
        let id = order.removeFirst()
        guard let delivery = deliveries.removeValue(forKey: id) else { deliverNext(); return }
        guard isCurrent(delivery) else {
            complete(delivery, accepted: false)
            deliverNext()
            return
        }
        guard let content = delivery.content else {
            removeNotification(id: id)
            deliverNext()
            return
        }
        delivering = true
        add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { [weak self] error in
            guard let self = self else { return }
            self.queue.async {
                let current = self.isCurrent(delivery)
                if !current {
                    // A late add may recreate the removed update. Clean up before the
                    // next delivery, which can reuse this ID after OFF → ON.
                    self.removeNotification(id: id)
                } else if let error = error {
                    self.log?("Notification delivery failed: \(error.localizedDescription)")
                } else {
                    let kind = content.categoryIdentifier == self.pendingCategory ? "destination" : (content.categoryIdentifier == self.updateCategory ? "update" : "completion")
                    self.log?("Notification accepted by macOS: \(kind)")
                }
                self.complete(delivery, accepted: error == nil && current)
                self.delivering = false
                self.deliverNext()
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(presentationOptions(for: notification.request.content))
    }

    func presentationOptions(for content: UNNotificationContent) -> UNNotificationPresentationOptions {
        if content.categoryIdentifier == updateCategory {
            let allowed = queue.sync {
                guard self.updateNotificationsEnabled else { return false }
                // Older builds/processes have no generation in this session.
                guard content.userInfo["updateSession"] as? String == self.updateSession else { return true }
                return content.userInfo["updateGeneration"] as? String == String(self.updateGeneration)
            }
            if !allowed { return [] }
        }
        return [.banner, .list, .sound]
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

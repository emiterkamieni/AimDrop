import Cocoa
import UserNotifications

// Standalone: swiftc Sources/Localization.swift Sources/TransferPresentation.swift
// Sources/TransferNotifications.swift tests/NotificationChecks.swift -o <temporary-path>/notification-checks
// All notification operations are injected; the live notification center is never initialized.
private func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                    file: StaticString = #file, line: UInt = #line) {
    precondition(condition(), message, file: file, line: line)
}

private let updateID = "aimdrop.update.available"
private let updateCategory = "AIMDROP_UPDATE_AVAILABLE"
private let updateURL = URL(string: "https://github.com/emiterkamieni/AimDrop/releases/tag/v1.1.0")!
private let visible: UNNotificationPresentationOptions = [.banner, .list, .sound]
private func transferID(_ id: String) -> String { "airfrajer.transfer." + id }

private enum Event: Equatable {
    case add(String)
    case removePending([String])
    case removeDelivered([String])
}

private func removal(_ id: String) -> [Event] { [.removePending([id]), .removeDelivered([id])] }

private final class TestCenter {
    struct Snapshot {
        let requests: [UNNotificationRequest]
        let events: [Event]
        let pending: Set<String>
        let delivered: Set<String>
    }
    private struct Submission {
        let request: UNNotificationRequest
        let completion: (Error?) -> Void
    }
    private let condition = NSCondition()
    private var submissions: [Submission] = []
    private var acknowledged: Set<Int> = []
    private var events: [Event] = []
    private var pending: Set<String> = []
    private var delivered: Set<String> = []

    var snapshot: Snapshot {
        condition.lock(); defer { condition.unlock() }
        return Snapshot(requests: submissions.map(\.request), events: events, pending: pending, delivered: delivered)
    }

    func add(_ request: UNNotificationRequest, _ completion: @escaping (Error?) -> Void) {
        condition.lock(); defer { condition.unlock() }
        submissions.append(Submission(request: request, completion: completion))
        pending.insert(request.identifier)
        events.append(.add(request.identifier))
        condition.broadcast()
    }

    func removePending(_ ids: [String]) {
        condition.lock(); defer { condition.unlock() }
        pending.subtract(ids)
        events.append(.removePending(ids))
        condition.broadcast()
    }

    func removeDelivered(_ ids: [String]) {
        condition.lock(); defer { condition.unlock() }
        delivered.subtract(ids)
        events.append(.removeDelivered(ids))
        condition.broadcast()
    }

    func acknowledge(_ index: Int, error: Error? = nil) {
        condition.lock()
        expect(submissions.indices.contains(index), "No such notification request")
        expect(acknowledged.insert(index).inserted, "Test acknowledged a request twice")
        let submission = submissions[index]
        pending.remove(submission.request.identifier)
        // Deliberately resurrect a removed request: the OS can finish an old add after removal.
        if error == nil { delivered.insert(submission.request.identifier) }
        condition.unlock()
        submission.completion(error)
    }

    func waitForAdds(_ count: Int) { wait { submissions.count >= count } }
    func waitForEvents(_ count: Int) { wait { events.count >= count } }

    private func wait(_ ready: () -> Bool) {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(3)
        while !ready() && condition.wait(until: deadline) {}
        expect(ready(), "Timed out waiting for a notification operation")
    }
}

private final class Results {
    var values: [String: Bool] = [:]
    func callback(_ label: String) -> (Bool) -> Void {
        { accepted in
            expect(Thread.isMainThread, "Notification completions must run on main")
            expect(self.values[label] == nil, "A notification must complete exactly once: \(label)")
            self.values[label] = accepted
        }
    }
}

private final class Harness {
    let center: TestCenter
    let notifications: TransferNotifications
    let results = Results()
    init() {
        let center = TestCenter()
        self.center = center
        notifications = TransferNotifications(add: center.add, removePending: center.removePending,
                                              removeDelivered: center.removeDelivered)
    }
    func update(_ label: String, version: String = "1.1.0", url: URL = updateURL) {
        notifications.updateAvailable(version: version, url: url, completion: results.callback(label))
    }
}

private func waitUntil(_ ready: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !ready() && Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    expect(ready(), "Timed out waiting for a main-thread callback")
}

@main struct NotificationChecks {
    static func main() {
        L10n.configure(.english)
        enabledSuccessAndFailure()
        disabledAndInvalidRequests()
        queuedDisable()
        inFlightDisable()
        offOnStaleAdd()
        delayedMainCompletion()
        coalescing()
        transferIsolation()
        foregroundPresentation()
        print("PASS: notification defaults, main-thread completions, disabled suppression, queued/in-flight cancellation, OFF→ON stale adds, delayed-main generation checks, coalescing, transfer isolation and foreground policy (injected center only)")
    }

    private static func enabledSuccessAndFailure() {
        let h = Harness()
        h.update("success")
        h.center.waitForAdds(1)
        let request = h.center.snapshot.requests[0]
        expect(request.identifier == updateID && request.trigger == nil, "Use the existing immediate update identifier")
        expect(request.content.categoryIdentifier == updateCategory, "Preserve the update action category")
        expect(request.content.userInfo["updateURL"] as? String == updateURL.absoluteString, "Keep the update action URL")
        expect(h.results.values.isEmpty, "An unacknowledged add cannot report success")
        DispatchQueue.global().async { h.center.acknowledge(0) }
        waitUntil { h.results.values["success"] != nil }
        expect(h.results.values["success"] == true, "Updates are enabled by default")
        expect(h.center.snapshot.events == [.add(updateID)], "Successful delivery needs no removal")
        expect(h.center.snapshot.delivered == [updateID], "Keep a successfully delivered update")

        h.update("failure")
        h.notifications.awaitingDestination(id: "after-error", count: 1)
        h.center.waitForAdds(2)
        h.center.acknowledge(1, error: NSError(domain: "NotificationChecks", code: 1))
        h.center.waitForAdds(3)
        waitUntil { h.results.values["failure"] != nil }
        expect(h.results.values["failure"] == false, "Failed OS acceptance must not mark a version notified")
        expect(h.center.snapshot.requests[2].identifier == transferID("after-error"), "An error must release the delivery queue")
        h.center.acknowledge(2)
    }

    private static func disabledAndInvalidRequests() {
        let h = Harness()
        h.notifications.setUpdateNotificationsEnabled(false)
        expect(h.center.snapshot.events == removal(updateID), "Disable must synchronously remove pending and delivered updates only")
        DispatchQueue.global().async { h.update("disabled") }
        waitUntil { h.results.values["disabled"] != nil }
        expect(h.results.values["disabled"] == false, "Disabled updates must complete false on main")
        expect(h.center.snapshot.events == removal(updateID), "A suppressed event must never reach the notification center")
        // Re-enabling must not replay an event suppressed while disabled.
        h.notifications.setUpdateNotificationsEnabled(true)
        expect(h.center.snapshot.requests.isEmpty, "Do not retain disabled events for later delivery")
        DispatchQueue.global().async {
            h.update("unsafe", url: URL(string: "https://example.com/update")!)
        }
        waitUntil { h.results.values["unsafe"] != nil }
        expect(h.results.values["unsafe"] == false && h.center.snapshot.requests.isEmpty,
               "Invalid update URLs must also complete false on main without a request")
    }

    private static func queuedDisable() {
        let h = Harness()
        h.notifications.awaitingDestination(id: "blocker", count: 1)
        h.center.waitForAdds(1)
        h.update("queued")
        h.notifications.awaitingDestination(id: "following", count: 2)
        h.notifications.setUpdateNotificationsEnabled(false)
        expect(h.center.snapshot.events == [.add(transferID("blocker"))] + removal(updateID),
               "Queued updates must be removed without disturbing the in-flight transfer")
        waitUntil { h.results.values["queued"] != nil }
        expect(h.results.values["queued"] == false && h.center.snapshot.requests.count == 1,
               "Reject queued completions without waiting for the blocking add")
        h.center.acknowledge(0)
        h.center.waitForAdds(2)
        expect(h.center.snapshot.requests.map(\.identifier) == [transferID("blocker"), transferID("following")],
               "Only the update may be pruned from the queue")
        expect(h.center.snapshot.delivered.contains(transferID("blocker")), "Keep delivered transfers while disabled")
        h.center.acknowledge(1)
    }

    private static func inFlightDisable() {
        let h = Harness()
        h.update("in-flight")
        h.center.waitForAdds(1)
        h.notifications.awaitingDestination(id: "following", count: 1)
        h.notifications.setUpdateNotificationsEnabled(false)
        expect(h.center.snapshot.events == [.add(updateID)] + removal(updateID), "Remove immediately, before the old acknowledgement")
        expect(!h.center.snapshot.pending.contains(updateID), "Disable removes pending updates synchronously")
        h.center.acknowledge(0)
        h.center.waitForAdds(2)
        expect(h.center.snapshot.events == [.add(updateID)] + removal(updateID) + removal(updateID) + [.add(transferID("following"))],
               "A stale add must be removed again before the next delivery")
        waitUntil { h.results.values["in-flight"] != nil }
        expect(h.results.values["in-flight"] == false, "Late OS success after disable is not notification success")
        expect(!h.center.snapshot.delivered.contains(updateID), "A stale acknowledgement must not resurrect the update")
        h.center.acknowledge(1)
    }

    private static func offOnStaleAdd() {
        let h = Harness()
        h.update("old")
        h.center.waitForAdds(1)
        h.notifications.setUpdateNotificationsEnabled(false)
        h.notifications.setUpdateNotificationsEnabled(true)
        h.update("fresh", version: "1.2.0")
        h.notifications.setUpdateNotificationsEnabled(true) // Same policy also fences earlier queue work.
        expect(h.center.snapshot.requests.count == 1, "The fresh update must wait for the old add acknowledgement")
        h.center.acknowledge(0)
        h.center.waitForAdds(2)
        expect(h.center.snapshot.events == [.add(updateID)] + removal(updateID) + removal(updateID) + [.add(updateID)],
               "OFF→ON still invalidates the old generation, with cleanup before reusing its ID")
        expect(h.center.snapshot.pending.contains(updateID) && !h.center.snapshot.delivered.contains(updateID),
               "Old cleanup must preserve the newly submitted update")
        waitUntil { h.results.values["old"] != nil }
        expect(h.results.values["old"] == false && h.results.values["fresh"] == nil, "Only the old completion should be rejected")
        h.center.acknowledge(1)
        waitUntil { h.results.values["fresh"] != nil }
        expect(h.results.values["fresh"] == true && h.center.snapshot.delivered.contains(updateID),
               "An update from the new enabled generation should succeed")
    }

    private static func delayedMainCompletion() {
        for reenable in [false, true] {
            let h = Harness()
            h.update("acknowledged")
            h.center.waitForAdds(1)
            h.center.acknowledge(0)
            // Main is intentionally not pumped: this fences the acknowledgement,
            // leaving its success callback queued behind this test's policy change.
            h.notifications.setUpdateNotificationsEnabled(true)
            expect(h.results.values.isEmpty, "The main completion must still be delayed")
            h.notifications.setUpdateNotificationsEnabled(false)
            expect(!h.center.snapshot.delivered.contains(updateID), "Disable removes an already acknowledged update")
            if reenable {
                h.notifications.setUpdateNotificationsEnabled(true)
                h.update("fresh", version: "1.2.0")
                h.center.waitForAdds(2)
                h.center.acknowledge(1)
                h.notifications.setUpdateNotificationsEnabled(true)
            }
            waitUntil { h.results.values.count == (reenable ? 2 : 1) }
            expect(h.results.values["acknowledged"] == false, "Revalidate the generation inside the delayed main callback, including OFF→ON")
            if reenable {
                expect(h.results.values["fresh"] == true && h.center.snapshot.delivered.contains(updateID),
                       "A delayed stale callback must not invalidate or remove a fresh notification")
            }
        }
    }

    private static func coalescing() {
        let h = Harness()
        h.notifications.awaitingDestination(id: "blocker", count: 1)
        h.center.waitForAdds(1)
        h.update("first", version: "1.1.0")
        h.update("second", version: "1.2.0")
        h.update("latest", version: "1.3.0")
        h.notifications.setUpdateNotificationsEnabled(true)
        waitUntil { h.results.values.count == 2 }
        expect(h.results.values["first"] == false && h.results.values["second"] == false, "Complete replaced queued updates exactly once")
        expect(h.center.snapshot.requests.count == 1, "Coalesced updates must wait behind the in-flight transfer")
        h.center.acknowledge(0)
        h.center.waitForAdds(2)
        expect(h.center.snapshot.requests[1].content.title == "AimDrop 1.3.0", "Deliver only the latest queued update")
        h.center.acknowledge(1)
        waitUntil { h.results.values["latest"] != nil }
        expect(h.results.values["latest"] == true && h.center.snapshot.requests.count == 2, "The latest coalesced update must succeed")
    }

    private static func transferIsolation() {
        let h = Harness()
        h.notifications.awaitingDestination(id: "saved", count: 1)
        h.center.waitForAdds(1)
        h.notifications.awaitingDestination(id: "saved", count: 2)
        h.notifications.cancel(id: "saved")
        h.notifications.awaitingDestination(id: "unsaved", count: 3)
        h.notifications.setUpdateNotificationsEnabled(false)
        h.center.acknowledge(0)
        h.center.waitForAdds(2)
        expect(h.center.snapshot.events == [.add(transferID("saved"))] + removal(updateID)
               + removal(transferID("saved")) + [.add(transferID("unsaved"))],
               "Transfer reminder coalescing/cancellation must retain its serialized cleanup")
        expect(!h.center.snapshot.delivered.contains(transferID("saved")), "A saved transfer cannot leave a late reminder")
        let request = h.center.snapshot.requests[1]
        expect(request.content.categoryIdentifier == "AIRFRAJER_BUFFERED"
               && request.content.threadIdentifier == "airfrajer.transfers"
               && request.content.userInfo["pendingID"] as? String == "unsaved", "Preserve transfer presentation and save-action routing")
        h.center.acknowledge(1)
        h.notifications.setUpdateNotificationsEnabled(false)
        expect(h.center.snapshot.delivered == [transferID("unsaved")], "Repeated disable must leave delivered transfers intact")
        h.notifications.cancel(id: "unsaved")
        h.center.waitForEvents(10)
        expect(h.center.snapshot.delivered.isEmpty, "Explicit transfer cancellation must still work while updates are off")
    }

    private static func foregroundPresentation() {
        let h = Harness()
        h.update("old")
        h.center.waitForAdds(1)
        let old = h.center.snapshot.requests[0].content
        let legacy = UNMutableNotificationContent()
        legacy.categoryIdentifier = updateCategory
        expect(h.notifications.presentationOptions(for: old) == visible, "Enabled current updates should present normally")
        expect(h.notifications.presentationOptions(for: legacy) == visible, "Keep presentation for legacy updates when enabled")
        h.notifications.setUpdateNotificationsEnabled(false)
        expect(h.notifications.presentationOptions(for: old).isEmpty && h.notifications.presentationOptions(for: legacy).isEmpty,
               "Foreground policy must suppress every update while disabled")
        for category in ["AIRFRAJER_BUFFERED", "AIRFRAJER_RECEIVED", ""] {
            let transfer = UNMutableNotificationContent()
            transfer.categoryIdentifier = category
            expect(h.notifications.presentationOptions(for: transfer) == visible, "Update policy must not suppress transfer or other categories")
        }
        h.notifications.setUpdateNotificationsEnabled(true)
        expect(h.notifications.presentationOptions(for: old).isEmpty, "OFF→ON cannot present an old in-flight generation")
        expect(h.notifications.presentationOptions(for: legacy) == visible, "Legacy notifications have no stale generation in this session")
        legacy.userInfo = ["updateSession": "previous-process", "updateGeneration": "9"]
        expect(h.notifications.presentationOptions(for: legacy) == visible, "Generation counters are scoped to their originating process")
        h.update("fresh")
        h.center.acknowledge(0)
        h.center.waitForAdds(2)
        expect(h.notifications.presentationOptions(for: h.center.snapshot.requests[1].content) == visible,
               "The current enabled generation should present after a toggle")
        h.center.acknowledge(1)
        waitUntil { h.results.values.count == 2 }
        expect(h.results.values["old"] == false && h.results.values["fresh"] == true, "Presentation checks must preserve delivery outcomes")
    }
}

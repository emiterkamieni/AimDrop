import Foundation

/// Two-party barrier: UI continuations/settings and authoritative worker idle.
/// Process exit alone is insufficient; require a correlated clean shutdown ACK.
final class UpdateRestartCoordinator {
    enum Phase { case idle, waiting, stopping, ready }
    private(set) var phase = Phase.idle
    private(set) var requestID: String?
    private var workerIdle = false
    private var acknowledged = false
    private var exited = false
    private var completion: ((Bool) -> Void)?
    var send: (([String: Any]) -> Bool)?
    var uiReady: (() -> Bool)?
    var onChange: (() -> Void)?
    var onFailure: (() -> Void)?
    var active: Bool { phase != .idle }
    var canCancel: Bool { phase == .idle || phase == .waiting }

    func begin(_ completion: @escaping (Bool) -> Void) {
        guard phase == .idle else { completion(false); return }
        requestID = UUID().uuidString.lowercased()
        self.completion = completion
        phase = .waiting; workerIdle = false; acknowledged = false; exited = false
        onChange?()
        guard send?(["command": "prepare_update", "request_id": requestID!]) == true else { fail(); return }
    }
    func receive(_ event: [String: Any]) {
        guard active, event["request_id"] as? String == requestID else { return }
        if event["event"] as? String == "update_status", phase == .waiting || phase == .stopping {
            if phase == .stopping {
                // The worker rechecks admission at commit. If it refuses,
                // return to cancellable waiting rather than assuming exit.
                guard event["idle"] as? Bool == false else { return }
                phase = .waiting; onChange?()
            }
            workerIdle = event["idle"] as? Bool == true
            advance()
        } else if event["event"] as? String == "shutdown_complete", phase == .stopping {
            acknowledged = true; finishIfReady()
        }
    }
    func advance() {
        guard phase == .waiting, workerIdle, uiReady?() == true else { return }
        phase = .stopping; onChange?()
        if send?(["command": "shutdown_when_idle", "request_id": requestID!]) != true { fail() }
    }
    func workerExited(success: Bool) {
        guard active else { return }
        guard phase == .stopping, success else { fail(); return }
        exited = true
        // The reader queue can deliver the last event after Process termination.
        finishIfReady()
        let id = requestID
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.requestID == id, self.phase == .stopping, !self.acknowledged else { return }
            self.fail()
        }
    }
    private func finishIfReady() {
        guard phase == .stopping, acknowledged, exited else { return }
        phase = .ready
        let callback = completion; completion = nil
        onChange?(); callback?(true)
    }
    func cancel() {
        guard canCancel, active else { return }
        if let requestID { _ = send?(["command": "cancel_update", "request_id": requestID]) }
        phase = .idle; requestID = nil; completion = nil
        onChange?()
    }
    func resetAfterInstallerFailure() {
        if phase == .ready { phase = .idle; requestID = nil; onChange?() }
        else { cancel() }
    }
    private func fail() {
        if let requestID { _ = send?(["command": "cancel_update", "request_id": requestID]) }
        phase = .idle; requestID = nil
        let callback = completion; completion = nil
        onChange?(); onFailure?(); callback?(false)
    }
}

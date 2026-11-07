import Foundation

struct AvailableUpdate: Equatable {
    let version: String
    let downloadURL: URL
    let releasePageURL: URL
    var build: String? = nil
}

enum UpdateCheckResult: Equatable {
    case available(AvailableUpdate), upToDate, noReleases
}

enum UpdateCheckError: Error { case busy, unavailable }

/// Only scheduling and notification deduplication live here. Sparkle is the
/// single source of update eligibility, version comparison and network I/O.
final class UpdateChecker {
    typealias Cancellation = () -> Void
    typealias Completion = (Result<UpdateCheckResult, Error>) -> Void
    typealias Probe = (@escaping Completion) -> Void
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Cancellation
    static let productionRepositoryURL = URL(string: "https://github.com/emiterkamieni/AimDrop")!
    static let checkInterval: TimeInterval = 86400
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let scheduler: Scheduler
    private let probe: Probe
    private let canProbe: () -> Bool
    private let prefix = "AimDrop.UpdateChecker.v1.emiterkamieni/aimdrop."
    private var scheduled: Cancellation?
    private var running = false
    private var flight: UUID?
    private var generation = UUID()
    var onAvailableUpdate: ((AvailableUpdate) -> Void)?

    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init,
         scheduler: @escaping Scheduler = UpdateChecker.schedule,
         canProbe: @escaping () -> Bool = { true }, probe: @escaping Probe = { $0(.failure(UpdateCheckError.unavailable)) }) {
        self.defaults = defaults; self.clock = clock; self.scheduler = scheduler
        self.canProbe = canProbe; self.probe = probe
    }
    deinit { scheduled?() }
    func start() { running = true; checkIfDue() }
    func stop() { running = false; generation = UUID(); flight = nil; scheduled?(); scheduled = nil }
    func manualCheckStarted() {
        // The foreground UI owns the result if a manual request joins a probe.
        flight = nil
        defaults.set(clock(), forKey: prefix + "lastAttempt"); scheduleNext()
    }
    func checkIfDue() {
        guard running else { return }
        if remaining == 0, flight == nil, canProbe() {
            let id = UUID(), epoch = generation
            flight = id
            defaults.set(clock(), forKey: prefix + "lastAttempt")
            probe { [weak self] result in
                guard let self, self.running, self.generation == epoch, self.flight == id else { return }
                self.flight = nil
                if case .success(.available(let update)) = result, !self.wasNotified(update) { self.onAvailableUpdate?(update) }
                self.scheduleNext()
            }
        }
        scheduleNext()
    }
    func markNotified(_ update: AvailableUpdate) {
        if let build = update.build {
            if let old = defaults.string(forKey: prefix + "notifiedBuild"), old.compare(build, options: .numeric) == .orderedDescending { return }
            defaults.set(build, forKey: prefix + "notifiedBuild")
        }
        defaults.set(update.version, forKey: prefix + "notifiedVersion")
    }
    private func wasNotified(_ update: AvailableUpdate) -> Bool {
        if let build = update.build, let old = defaults.string(forKey: prefix + "notifiedBuild") { return build == old }
        return defaults.string(forKey: prefix + "notifiedVersion") == update.version
    }
    private var remaining: TimeInterval {
        let now = clock()
        guard let last = defaults.object(forKey: prefix + "lastAttempt") as? Date, last.timeIntervalSince1970.isFinite else { return 0 }
        if last > now { defaults.set(now, forKey: prefix + "lastAttempt"); return Self.checkInterval }
        return max(0, Self.checkInterval - now.timeIntervalSince(last))
    }
    private func scheduleNext() {
        scheduled?(); scheduled = nil
        guard running else { return }
        let epoch = generation
        let delay = remaining
        scheduled = scheduler(delay > 0 ? delay : 60) { [weak self] in
            guard let self, self.generation == epoch else { return }
            self.checkIfDue()
        }
    }
    private static func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> Cancellation {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}

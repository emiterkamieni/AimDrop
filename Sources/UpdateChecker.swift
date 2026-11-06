import Foundation

struct AvailableUpdate: Equatable {
    let version: String
    let downloadURL: URL
    let releasePageURL: URL
}

enum UpdateCheckResult: Equatable {
    case available(AvailableUpdate)
    case upToDate
    case noReleases
}

/// Developer diagnostics only; the UI translates these cases into user-facing text.
enum UpdateCheckError: Error, CustomStringConvertible {
    case invalidCurrentVersion(String)
    case invalidRepositoryURL
    case invalidReleaseVersion(String)
    case invalidResponse
    case unsafeReleaseURL
    case responseTooLarge
    case httpStatus(Int)
    case network(code: Int)
    case timedOut

    var description: String {
        switch self {
        case .invalidCurrentVersion(let version): return "Invalid application semantic version: \(version)"
        case .invalidRepositoryURL: return "Expected an HTTPS GitHub repository URL."
        case .invalidReleaseVersion(let version): return "Invalid release semantic version: \(version)"
        case .invalidResponse: return "Invalid GitHub release response."
        case .unsafeReleaseURL: return "Release page URL does not belong to the configured GitHub repository and tag."
        case .responseTooLarge: return "GitHub release response exceeds the size limit."
        case .httpStatus(let status): return "GitHub release request returned HTTP \(status)."
        case .network(let code): return "GitHub release request failed with network error \(code)."
        case .timedOut: return "GitHub release request timed out."
        }
    }
}

/// SemVer precedence, with an optional Git tag `v` prefix. Build metadata does not
/// affect equality or precedence. Numeric identifiers never overflow an integer.
struct UpdateVersion: Comparable {
    let string: String
    private let numbers: [String]
    private let prerelease: [String]
    var isPrerelease: Bool { !prerelease.isEmpty }

    init?(_ value: String) {
        let string = value.hasPrefix("v") ? String(value.dropFirst()) : value
        guard !string.isEmpty, string.utf8.count <= 256 else { return nil }
        let metadata = string.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard metadata.count <= 2 else { return nil }
        if metadata.count == 2 {
            guard Self.identifiers(metadata[1], forbidLeadingZero: false) != nil else { return nil }
        }
        let main = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let numbers = main[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard numbers.count == 3,
              numbers.allSatisfy({ Self.isNumeric($0) && ($0.count == 1 || !$0.hasPrefix("0")) }) else { return nil }
        var prerelease: [String] = []
        if main.count == 2 {
            guard let identifiers = Self.identifiers(main[1], forbidLeadingZero: true) else { return nil }
            prerelease = identifiers
        }
        self.string = string
        self.numbers = numbers
        self.prerelease = prerelease
    }

    private static func isNumeric(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func identifiers(_ value: String, forbidLeadingZero: Bool) -> [String]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            } && !(forbidLeadingZero && isNumeric(part) && part.count > 1 && part.hasPrefix("0"))
        }) else { return nil }
        return parts
    }

    private static func numericLess(_ left: String, _ right: String) -> Bool {
        left.count == right.count ? left.utf8.lexicographicallyPrecedes(right.utf8) : left.count < right.count
    }

    static func == (left: Self, right: Self) -> Bool {
        left.numbers == right.numbers && left.prerelease == right.prerelease
    }

    static func < (left: Self, right: Self) -> Bool {
        for (a, b) in zip(left.numbers, right.numbers) where a != b { return numericLess(a, b) }
        if left.prerelease.isEmpty || right.prerelease.isEmpty {
            return !left.prerelease.isEmpty && right.prerelease.isEmpty
        }
        for (a, b) in zip(left.prerelease, right.prerelease) where a != b {
            let aNumeric = isNumeric(a), bNumeric = isNumeric(b)
            if aNumeric && bNumeric { return numericLess(a, b) }
            if aNumeric != bNumeric { return aNumeric }
            return a.utf8.lexicographicallyPrecedes(b.utf8)
        }
        return left.prerelease.count < right.prerelease.count
    }
}

final class UpdateChecker {
    typealias Cancellation = () -> Void
    typealias Completion = (Result<UpdateCheckResult, Error>) -> Void
    typealias Transport = (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Cancellation
    /// One-shot scheduling, using elapsed time. The returned closure cancels the action.
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Cancellation

    static let productionRepositoryURL = URL(string: "https://github.com/emiterkamieni/AimDrop")!
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let maximumResponseBytes = 2 * 1024 * 1024

    /// Set on the main thread. Only automatic checks use this callback. If a manual
    /// check joins an automatic request, its completion owns presentation instead.
    var onAvailableUpdate: ((AvailableUpdate) -> Void)?

    private let currentVersion: String
    private let repository: Repository?
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let transport: Transport
    private let scheduler: Scheduler
    private let requestTimeout: TimeInterval
    private let lastAttemptKey: String
    private let notifiedVersionKey: String
    private var running = false
    private var cancelScheduledCheck: Cancellation?
    private var scheduledCheckID: UUID?
    private var flight: Flight?

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
         defaults: UserDefaults = .standard,
         repositoryURL: URL = UpdateChecker.productionRepositoryURL,
         clock: @escaping () -> Date = Date.init,
         transport: @escaping Transport = UpdateChecker.systemTransport,
         scheduler: @escaping Scheduler = UpdateChecker.systemSchedule,
         requestTimeout: TimeInterval = 30) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.repository = Repository(repositoryURL)
        self.clock = clock
        self.transport = transport
        self.scheduler = scheduler
        self.requestTimeout = requestTimeout.isFinite ? min(60, max(1, requestTimeout)) : 30
        let namespace = "AimDrop.UpdateChecker.v1." + (repository?.identity ?? "invalid")
        lastAttemptKey = namespace + ".lastAttempt"
        notifiedVersionKey = namespace + ".notifiedVersion"
    }

    deinit {
        cancelScheduledCheck?()
        flight?.cancelTimeout?()
        flight?.cancelRequest?()
    }

    /// Starts a persistent 24-hour cadence, checking immediately only when due.
    func start() {
        onMain { [weak self] in
            guard let self else { return }
            self.running = true
            self.checkDueOnMain()
        }
    }

    /// Stops automatic work; a joined manual request still receives its completion.
    func stop() {
        onMain { [weak self] in
            guard let self else { return }
            self.running = false
            self.scheduledCheckID = nil
            self.cancelScheduledCheck?()
            self.cancelScheduledCheck = nil
            if let flight = self.flight {
                flight.automatic = false
                if flight.completions.isEmpty {
                    self.flight = nil
                    flight.cancelTimeout?()
                    flight.cancelRequest?()
                }
            }
        }
    }

    /// Also call on wake/activation; this does not require the recurring timer.
    func checkIfDue() { onMain { [weak self] in self?.checkDueOnMain() } }

    /// Always checks, even inside the automatic interval or after notification.
    /// All coalesced manual completions are delivered on the main thread.
    func checkManually(completion: @escaping Completion) {
        onMain { [weak self] in self?.begin(automatic: false, completion: completion) }
    }

    /// Call only after the UI successfully schedules its notification/presentation.
    /// An older asynchronous UI completion cannot overwrite a newer notification.
    func markNotified(_ update: AvailableUpdate) {
        onMain { [weak self] in
            guard let self, let version = UpdateVersion(update.version), !version.isPrerelease else { return }
            if let previous = self.notifiedVersion, version <= previous { return }
            self.defaults.set(version.string, forKey: self.notifiedVersionKey)
        }
    }

    private var notifiedVersion: UpdateVersion? {
        defaults.string(forKey: notifiedVersionKey).flatMap(UpdateVersion.init)
    }

    private func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }

    private func secondsUntilDue() -> TimeInterval {
        let now = clock()
        guard let last = defaults.object(forKey: lastAttemptKey) as? Date,
              last.timeIntervalSince1970.isFinite else { return 0 }
        // A corrected system clock (or a corrupt future timestamp) must never
        // postpone checks indefinitely. Persist the new anchor across restarts.
        if last > now {
            defaults.set(now, forKey: lastAttemptKey)
            return Self.checkInterval
        }
        return max(0, Self.checkInterval - now.timeIntervalSince(last))
    }

    private func checkDueOnMain() {
        if secondsUntilDue() == 0 { begin(automatic: true, completion: nil) }
        scheduleNextCheck()
    }

    private func scheduleNextCheck() {
        scheduledCheckID = nil
        cancelScheduledCheck?()
        cancelScheduledCheck = nil
        guard running else { return }
        let id = UUID()
        scheduledCheckID = id
        cancelScheduledCheck = scheduler(max(1, secondsUntilDue())) { [weak self] in
            self?.onMain { [weak self] in
                guard let self, self.running, self.scheduledCheckID == id else { return }
                self.scheduledCheckID = nil
                self.cancelScheduledCheck = nil
                self.checkDueOnMain()
            }
        }
    }

    private func begin(automatic: Bool, completion: Completion?) {
        if let flight {
            flight.automatic = flight.automatic || automatic
            if let completion { flight.completions.append(completion) }
            return
        }
        let flight = Flight(automatic: automatic, completion: completion)
        self.flight = flight
        // Persist attempts, including failures and manual checks, before starting
        // transport so restarts cannot produce a burst of requests.
        defaults.set(clock(), forKey: lastAttemptKey)
        scheduleNextCheck()
        guard UpdateVersion(currentVersion) != nil else {
            finish(flight.id, .failure(UpdateCheckError.invalidCurrentVersion(currentVersion)))
            return
        }
        guard let repository else {
            finish(flight.id, .failure(UpdateCheckError.invalidRepositoryURL))
            return
        }
        var request = URLRequest(url: repository.apiURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: requestTimeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("AimDrop-UpdateChecker", forHTTPHeaderField: "User-Agent")
        let id = flight.id
        // This watchdog also bounds injected transports or a stalled URLSession.
        flight.cancelTimeout = scheduler(requestTimeout) { [weak self] in
            self?.onMain { [weak self] in self?.finish(id, .failure(UpdateCheckError.timedOut)) }
        }
        let cancel = transport(request) { [weak self] data, response, error in
            self?.onMain { [weak self] in
                guard let self, self.flight?.id == id else { return }
                let result = Result { try self.interpret(data: data, response: response, error: error, repository: repository) }
                self.finish(id, result)
            }
        }
        // A test transport may finish synchronously before returning cancellation.
        if self.flight?.id == id { flight.cancelRequest = cancel } else { cancel() }
    }

    private func finish(_ id: UUID, _ result: Result<UpdateCheckResult, Error>) {
        guard let flight, flight.id == id else { return }
        self.flight = nil
        flight.cancelTimeout?()
        flight.cancelRequest?()
        scheduleNextCheck()
        if !flight.completions.isEmpty {
            for completion in flight.completions { completion(result) }
        } else if flight.automatic, case .success(.available(let update)) = result,
                  let version = UpdateVersion(update.version), notifiedVersion.map({ version > $0 }) ?? true {
            // Deliberately not persisted here: UI scheduling may fail. A future
            // due check can retry unless markNotified confirms success.
            onAvailableUpdate?(update)
        }
    }

    private func interpret(data: Data?, response: URLResponse?, error: Error?, repository: Repository) throws -> UpdateCheckResult {
        if let error {
            let code = (error as NSError).code
            if (error as NSError).domain == NSURLErrorDomain && code == URLError.timedOut.rawValue {
                throw UpdateCheckError.timedOut
            }
            throw UpdateCheckError.network(code: code)
        }
        guard let response = response as? HTTPURLResponse, response.url == repository.apiURL else {
            throw UpdateCheckError.invalidResponse
        }
        if response.statusCode == 404 { return .noReleases }
        guard response.statusCode == 200 else { throw UpdateCheckError.httpStatus(response.statusCode) }
        guard let data else { throw UpdateCheckError.invalidResponse }
        guard data.count <= Self.maximumResponseBytes else { throw UpdateCheckError.responseTooLarge }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw UpdateCheckError.invalidResponse
        }
        guard !release.draft && !release.prerelease else { return .noReleases }
        guard let version = UpdateVersion(release.tag_name) else {
            throw UpdateCheckError.invalidReleaseVersion(release.tag_name)
        }
        guard !version.isPrerelease else { return .noReleases }
        guard let page = repository.releaseURL(release.html_url, tag: release.tag_name) else {
            throw UpdateCheckError.unsafeReleaseURL
        }
        guard let current = UpdateVersion(currentVersion), version > current else { return .upToDate }
        let assets = (release.assets ?? []).compactMap { asset -> (URL, Int)? in
            guard asset.state == nil || asset.state == "uploaded",
                  let score = Self.assetScore(asset.name),
                  let url = repository.assetURL(asset.browser_download_url, tag: release.tag_name, name: asset.name) else { return nil }
            return (url, score)
        }
        let download = assets.max { $0.1 < $1.1 }?.0 ?? page
        return .available(AvailableUpdate(version: version.string, downloadURL: download, releasePageURL: page))
    }

    private static func assetScore(_ name: String) -> Int? {
        let name = name.lowercased()
        let dmg = name.hasSuffix(".dmg")
        guard dmg || name.hasSuffix(".zip") else { return nil }
        let tokens = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let forbidden = ["windows", "win", "win32", "win64", "linux", "ubuntu", "android", "ios", "intel", "amd64", "x64"]
        guard !tokens.contains(where: forbidden.contains), !name.contains("x86") else { return nil }
        let mac = dmg || tokens.contains(where: ["macos", "mac", "darwin", "osx"].contains)
        guard mac else { return nil }
        let arm = tokens.contains(where: ["arm64", "aarch64", "applesilicon"].contains)
            || name.contains("apple-silicon") || name.contains("apple_silicon")
        let universal = tokens.contains("universal") || tokens.contains("universal2")
        guard arm || universal else { return nil }
        return (arm ? 100 : 50) + (dmg ? 10 : 0)
    }

    private final class Flight {
        let id = UUID()
        var automatic: Bool
        var completions: [Completion]
        var cancelRequest: Cancellation?
        var cancelTimeout: Cancellation?
        init(automatic: Bool, completion: Completion?) {
            self.automatic = automatic
            completions = completion.map { [$0] } ?? []
        }
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let html_url: String
        let assets: [Asset]?
    }

    private struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let state: String?
    }

    private struct Repository {
        let owner: String
        let name: String
        var identity: String { (owner + "/" + name).lowercased() }
        var apiURL: URL { URL(string: "https://api.github.com/repos/\(owner)/\(name)/releases/latest")! }

        init?(_ url: URL) {
            guard let parts = Self.path(url.absoluteString), parts.count == 2,
                  parts.allSatisfy({ part in part.utf8.allSatisfy {
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                          || $0 == 45 || $0 == 46 || $0 == 95
                  } }) else { return nil }
            owner = parts[0]
            name = parts[1]
        }

        private static func path(_ value: String) -> [String]? {
            guard let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443, url.query == nil, url.fragment == nil else { return nil }
            var encoded = url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard encoded.first == "" else { return nil }
            encoded.removeFirst()
            if encoded.last == "" { encoded.removeLast() }
            let parts = encoded.compactMap { $0.removingPercentEncoding }
            guard parts.count == encoded.count, parts.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\")
                    && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            }) else { return nil }
            return parts
        }

        private func matches(_ parts: [String]) -> Bool {
            parts.count >= 2 && parts[0].lowercased() == owner.lowercased() && parts[1].lowercased() == name.lowercased()
        }

        func releaseURL(_ value: String, tag: String) -> URL? {
            guard let parts = Self.path(value), matches(parts), parts.count == 5,
                  parts[2] == "releases", parts[3] == "tag", parts[4] == tag else { return nil }
            return URL(string: value)
        }

        func assetURL(_ value: String, tag: String, name: String) -> URL? {
            guard let parts = Self.path(value), matches(parts), parts.count == 6,
                  parts[2] == "releases", parts[3] == "download", parts[4] == tag, parts[5] == name else { return nil }
            return URL(string: value)
        }
    }

    private static func systemSchedule(after delay: TimeInterval, action: @escaping () -> Void) -> Cancellation {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    private static func systemTransport(request: URLRequest,
                                        completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> Cancellation {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        let task = session.dataTask(with: request) { data, response, error in
            completion(data, response, error)
            session.finishTasksAndInvalidate()
        }
        task.resume()
        return { task.cancel(); session.invalidateAndCancel() }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

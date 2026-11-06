import Foundation

// Standalone: swiftc Sources/UpdateChecker.swift tests/UpdateChecks.swift -o <temporary-path>/update-checks
// Every request, timer, clock and preferences domain is isolated from production.
private func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                    file: StaticString = #file, line: UInt = #line) {
    precondition(condition(), message, file: file, line: line)
}

private func expectError(_ result: Result<UpdateCheckResult, Error>, _ message: String,
                         matches: (UpdateCheckError) -> Bool) {
    guard case .failure(let error) = result, let typed = error as? UpdateCheckError, matches(typed) else {
        preconditionFailure("\(message): \(result)")
    }
}

private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

private final class TestScheduler {
    final class Event {
        let delay: TimeInterval
        let action: () -> Void
        var cancelled = false
        var fired = false
        init(_ delay: TimeInterval, _ action: @escaping () -> Void) { self.delay = delay; self.action = action }
        func fire(evenIfCancelled: Bool = false) {
            guard !fired && (!cancelled || evenIfCancelled) else { return }
            fired = true
            action()
        }
    }
    var events: [Event] = []
    var pending: [Event] { events.filter { !$0.cancelled && !$0.fired } }
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> UpdateChecker.Cancellation {
        let event = Event(delay, action)
        events.append(event)
        return { event.cancelled = true }
    }
}

private final class TestTransport {
    final class Request {
        let request: URLRequest
        let completion: (Data?, URLResponse?, Error?) -> Void
        var cancelled = false
        init(_ request: URLRequest, _ completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
            self.request = request
            self.completion = completion
        }
        func respond(_ body: Data? = nil, status: Int = 200, error: Error? = nil, url: URL? = nil) {
            let response = HTTPURLResponse(url: url ?? request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            completion(body, response, error)
        }
    }
    var requests: [Request] = []
    func send(_ request: URLRequest, _ completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> UpdateChecker.Cancellation {
        expect(Thread.isMainThread, "Transport setup must be serialized on main")
        let pending = Request(request, completion)
        requests.append(pending)
        return { pending.cancelled = true }
    }
}

private final class Harness {
    let suite = "AimDrop.UpdateChecks." + UUID().uuidString
    let defaults: UserDefaults
    let clock = TestClock()
    let scheduler = TestScheduler()
    let transport = TestTransport()
    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }
    deinit { defaults.removePersistentDomain(forName: suite) }
    func checker(version: String = "1.0.0", repository: URL = UpdateChecker.productionRepositoryURL,
                 defaults: UserDefaults? = nil, timeout: TimeInterval = 30) -> UpdateChecker {
        UpdateChecker(currentVersion: version, defaults: defaults ?? self.defaults, repositoryURL: repository,
                      clock: { [clock] in clock.now }, transport: transport.send, scheduler: scheduler.schedule,
                      requestTimeout: timeout)
    }
    func manual(_ checker: UpdateChecker, body: Data? = release(), status: Int = 200,
                error: Error? = nil, url: URL? = nil) -> Result<UpdateCheckResult, Error> {
        var result: Result<UpdateCheckResult, Error>?
        let previous = transport.requests.count
        checker.checkManually {
            expect(Thread.isMainThread, "Manual callback must run on main")
            result = $0
        }
        if result == nil {
            expect(transport.requests.count == previous + 1, "Expected one new manual request")
            transport.requests.last!.respond(body, status: status, error: error, url: url)
        }
        return result!
    }
}

private let repo = "https://github.com/emiterkamieni/AimDrop"
private func release(_ version: String = "v1.1.0", page: String? = nil, draft: Bool = false,
                     prerelease: Bool = false, assets: [[String: Any]] = []) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "tag_name": version, "draft": draft, "prerelease": prerelease,
        "html_url": page ?? "\(repo)/releases/tag/\(version)", "assets": assets,
    ])
}

private func asset(_ name: String, version: String = "v1.1.0", url: String? = nil, state: String = "uploaded") -> [String: Any] {
    ["name": name, "browser_download_url": url ?? "\(repo)/releases/download/\(version)/\(name)", "state": state]
}

private func available(_ result: Result<UpdateCheckResult, Error>) -> AvailableUpdate {
    guard case .success(.available(let update)) = result else { preconditionFailure("Expected update, got \(result)") }
    return update
}

private func success(_ result: Result<UpdateCheckResult, Error>, _ expected: UpdateCheckResult) {
    guard case .success(let actual) = result else { preconditionFailure("Expected success, got \(result)") }
    expect(actual == expected, "Unexpected result: \(actual), expected \(expected)")
}

private func waitUntil(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    expect(condition(), "Timed out waiting for a main-thread callback")
}

@main struct UpdateChecks {
    static func main() {
        versions()
        releasesAndAssets()
        responsesAndErrors()
        safeURLs()
        persistenceAndClock()
        schedulingAndStop()
        coalescing()
        notificationDedupe()
        timeouts()
        print("PASS: SemVer, stable releases/assets, repository URL validation, typed errors, persistent 24h cadence/clock rollback, scheduling/stop, main-thread coalescing, notification dedupe, bounded timeouts and stale responses")
    }

    private static func versions() {
        let order = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
                     "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0"]
        for (index, first) in order.enumerated() {
            for second in order.dropFirst(index + 1) {
                expect(UpdateVersion(first)! < UpdateVersion(second)!, "Incorrect SemVer precedence: \(first), \(second)")
            }
        }
        for (older, newer) in [("1.9.99", "1.10.0"), ("9.99.99", "10.0.0"),
                               ("1.0.0-9", "1.0.0-10"), ("1.0.0-999", "1.0.0-alpha"),
                               ("1.0.0-Beta", "1.0.0-alpha"),
                               ("999999999999999999999999.0.0", "1000000000000000000000000.0.0"),
                               ("1.0.0-999999999999999999999999", "1.0.0-1000000000000000000000000")] {
            expect(UpdateVersion(older)! < UpdateVersion(newer)!, "Numeric identifiers must not sort lexically or overflow")
        }
        expect(UpdateVersion("v1.2.3") == UpdateVersion("1.2.3+build.001"), "Prefix/build metadata must not affect precedence")
        expect(UpdateVersion("1.2.3-rc.1+one") == UpdateVersion("1.2.3-rc.1+two"), "Prerelease metadata must not affect equality")
        for invalid in ["", "v", "1", "1.2", "1.2.3.4", "vv1.2.3", "01.2.3", "1.02.3", "1.2.03",
                        "1.2.3-01", "1.2.3-rc..1", "1.2.3-", "1.2.3+", "1.2.3+abc..def", "1.2.3+one+two",
                        " 1.2.3", "1.2.3\n", "1.2.3-😀", "1.2.3-rc_1", "1.2.3+\u{0001}"] {
            expect(UpdateVersion(invalid) == nil, "Invalid SemVer was accepted: \(invalid.debugDescription)")
        }
    }

    private static func releasesAndAssets() {
        let h = Harness(), checker = h.checker(version: "1.9.0")
        let tag = "v1.10.0"
        let preferred = "AimDrop-macOS-arm64.dmg"
        let payload = release(tag, assets: [
            asset("AimDrop-linux-arm64.zip", version: tag), asset("AimDrop-macOS-x86_64.dmg", version: tag),
            asset("AimDrop-macOS-universal.dmg", version: tag), asset("AimDrop-macOS-arm64.zip", version: tag),
            asset(preferred, version: tag), asset("AimDrop-macOS-arm64.exe", version: tag),
        ])
        let update = available(h.manual(checker, body: payload))
        expect(update.version == "1.10.0", "Display version should strip the v prefix")
        expect(update.downloadURL.lastPathComponent == preferred, "Prefer macOS arm64 DMG over ZIP/universal/other architectures")
        expect(update.releasePageURL.absoluteString == "\(repo)/releases/tag/\(tag)", "Keep the validated release page")
        let request = h.transport.requests[0].request
        expect(request.url?.absoluteString == "https://api.github.com/repos/emiterkamieni/AimDrop/releases/latest", "Use public latest stable endpoint")
        expect(request.httpMethod == "GET" && request.httpBody == nil, "Checking must not mutate or download a release asset")
        expect(request.timeoutInterval == 30 && request.cachePolicy == .reloadIgnoringLocalCacheData, "Bound timeout and avoid stale cached releases")
        expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json", "Use GitHub JSON API")
        expect(request.value(forHTTPHeaderField: "Authorization") == nil, "Public updates must not need credentials")
        expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28", "Pin the API schema")

        let older = h.checker()
        for candidates in [[], [asset("source.zip")], [asset("AimDrop-macOS-x64.dmg")], [asset("AimDrop-windows-arm64.zip")],
                           [asset("AimDrop-macOS-arm64.dmg", state: "starter")], [asset("AimDrop-linux-arm64.dmg")]] {
            let fallback = available(h.manual(older, body: release(assets: candidates)))
            expect(fallback.downloadURL == fallback.releasePageURL, "No matching uploaded safe asset must fall back to the page")
        }
        for name in ["AimDrop-darwin-aarch64.zip", "AimDrop-arm64.dmg", "AimDrop-macOS-universal2.zip", "AimDrop-apple-silicon.dmg"] {
            expect(available(h.manual(older, body: release(assets: [asset(name)]))).downloadURL.lastPathComponent == name,
                   "Recognize supported macOS ARM/universal naming: \(name)")
        }
        let prereleaseInstalled = h.checker(version: "1.1.0-rc.1")
        expect(available(h.manual(prereleaseInstalled)).version == "1.1.0", "Stable must upgrade the installed prerelease")
        success(h.manual(h.checker(version: "v1.1.0+local")), .upToDate)
        success(h.manual(h.checker(version: "1.10.0")), .upToDate)
    }

    private static func responsesAndErrors() {
        let h = Harness(), checker = h.checker()
        success(h.manual(checker, body: nil, status: 404), .noReleases)
        success(h.manual(checker, body: release(draft: true)), .noReleases)
        success(h.manual(checker, body: release(prerelease: true)), .noReleases)
        success(h.manual(checker, body: release("v9.0.0-beta.1")), .noReleases)
        for status in [301, 401, 403, 429, 500, 503] {
            expectError(h.manual(checker, body: nil, status: status), "HTTP status must be preserved") {
                if case .httpStatus(status) = $0 { return true }; return false
            }
        }
        for payload in [nil, Data(), Data("not json".utf8), Data("{}".utf8)] as [Data?] {
            expectError(h.manual(checker, body: payload), "Malformed response must be typed") {
                if case .invalidResponse = $0 { return true }; return false
            }
        }
        expectError(h.manual(checker, body: release("release-tomorrow")), "Invalid release tag must not be compared lexically") {
            if case .invalidReleaseVersion("release-tomorrow") = $0 { return true }; return false
        }
        expectError(h.manual(checker, body: Data(repeating: 32, count: UpdateChecker.maximumResponseBytes + 1)), "Enforce response bound") {
            if case .responseTooLarge = $0 { return true }; return false
        }
        expectError(h.manual(checker, error: URLError(.notConnectedToInternet)), "Network failure must be typed") {
            if case .network(code: URLError.notConnectedToInternet.rawValue) = $0 { return true }; return false
        }
        expectError(h.manual(checker, error: URLError(.timedOut)), "URLSession timeout must be typed") {
            if case .timedOut = $0 { return true }; return false
        }
        expectError(h.manual(checker, url: URL(string: "https://example.com/redirect")!), "Reject responses redirected away from the API") {
            if case .invalidResponse = $0 { return true }; return false
        }
        let requests = h.transport.requests.count
        expectError(h.manual(h.checker(version: "unknown")), "Invalid installed version must fail before transport") {
            if case .invalidCurrentVersion("unknown") = $0 { return true }; return false
        }
        expect(h.transport.requests.count == requests, "Do not request with an invalid installed version")
        var nonHTTP: Result<UpdateCheckResult, Error>?
        checker.checkManually { nonHTTP = $0 }
        h.transport.requests.last!.completion(Data(), URLResponse(url: URL(string: repo)!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), nil)
        expectError(nonHTTP!, "Reject non-HTTP response") { if case .invalidResponse = $0 { return true }; return false }
    }

    private static func safeURLs() {
        let h = Harness(), checker = h.checker()
        let suffix = "/emiterkamieni/AimDrop/releases/tag/v1.1.0"
        let badPages = [
            "http://github.com\(suffix)", "https://github.com.evil.test\(suffix)", "https://evil.test\(suffix)",
            "https://github.com@evil.test\(suffix)", "https://user@github.com\(suffix)", "https://github.com:8443\(suffix)",
            "https://github.com/emiterkamieni/AimDrop-fork/releases/tag/v1.1.0",
            "https://github.com/other/AimDrop/releases/tag/v1.1.0", "\(repo)/releases/tag/v2.0.0",
            "\(repo)/releases/tag/v1.1.0?next=https://evil.test", "\(repo)/releases/tag/v1.1.0#redirect",
            "\(repo)/../evil/releases/tag/v1.1.0", "\(repo)/%2e%2e/evil/releases/tag/v1.1.0",
            "https://github.com/emiterkamieni/AimDrop%2fevil/releases/tag/v1.1.0",
            "\(repo)/releases/tag/v1.1.0%2F..", "\(repo)/releases/tag/v1.1.0/extra",
            "\(repo)//releases/tag/v1.1.0", "\(repo)/releases/tag/v1.1.0%00",
            "file:///tmp/update.dmg", "javascript:alert(1)", "/emiterkamieni/AimDrop/releases/tag/v1.1.0",
        ]
        for page in badPages {
            expectError(h.manual(checker, body: release(page: page)), "Unsafe page accepted: \(page)") {
                if case .unsafeReleaseURL = $0 { return true }; return false
            }
        }
        let name = "AimDrop-macOS-arm64.dmg"
        let badAssets = [
            "http://github.com/emiterkamieni/AimDrop/releases/download/v1.1.0/\(name)",
            "https://github.com.evil.test/emiterkamieni/AimDrop/releases/download/v1.1.0/\(name)",
            "https://github.com/other/AimDrop/releases/download/v1.1.0/\(name)",
            "https://github.com/emiterkamieni/AimDrop-fork/releases/download/v1.1.0/\(name)",
            "https://user@github.com/emiterkamieni/AimDrop/releases/download/v1.1.0/\(name)",
            "\(repo)/releases/download/v2.0.0/\(name)", "\(repo)/releases/download/v1.1.0/different.dmg",
            "\(repo)/releases/download/v1.1.0/\(name)?redirect=evil", "\(repo)/releases/download/v1.1.0/..%2f\(name)",
            "https://objects.githubusercontent.com/asset.dmg", "file:///tmp/\(name)",
        ]
        for url in badAssets {
            let update = available(h.manual(checker, body: release(assets: [asset(name, url: url)])))
            expect(update.downloadURL == update.releasePageURL, "Unsafe asset should be ignored: \(url)")
        }
        let safeZIP = "AimDrop-macOS-arm64.zip"
        expect(available(h.manual(checker, body: release(assets: [asset(name, url: "https://evil.test/update.dmg"), asset(safeZIP)]))).downloadURL.lastPathComponent == safeZIP,
               "An unsafe preferred asset must not hide a safe ZIP")
        _ = available(h.manual(checker, body: release(page: "https://GITHUB.COM:443/EMITERKAMIENI/aimdrop/releases/tag/v1.1.0")))

        for url in ["http://github.com/owner/repo", "https://evil.test/owner/repo", "https://github.com/owner/repo/extra",
                    "https://user@github.com/owner/repo", "https://github.com/owner/repo?query", "https://github.com/owner/%2e%2e"] {
            expectError(h.manual(h.checker(repository: URL(string: url)!)), "Reject unsafe repository configuration") {
                if case .invalidRepositoryURL = $0 { return true }; return false
            }
        }
        let custom = h.checker(repository: URL(string: "https://github.com/TestOwner/TestRepo")!)
        let customPage = "https://github.com/TestOwner/TestRepo/releases/tag/v1.1.0"
        let update = available(h.manual(custom, body: release(page: customPage)))
        expect(update.releasePageURL.absoluteString == customPage, "Allow an explicitly configured public repository")
        expect(h.transport.requests.last!.request.url!.absoluteString == "https://api.github.com/repos/TestOwner/TestRepo/releases/latest", "Derive endpoint from configuration")
        expectError(h.manual(custom), "A configured repository must not accept the production repository's release") {
            if case .unsafeReleaseURL = $0 { return true }; return false
        }
    }

    private static func persistenceAndClock() {
        let h = Harness(), first = h.checker()
        first.start()
        expect(h.transport.requests.count == 1, "First launch should check")
        first.checkIfDue(); first.start()
        expect(h.transport.requests.count == 1, "Repeated activation/start must coalesce")
        first.stop()
        expect(h.transport.requests[0].cancelled, "Stop should cancel an automatic request")
        let restarted = h.checker(defaults: UserDefaults(suiteName: h.suite)!)
        restarted.start()
        expect(h.transport.requests.count == 1, "Persist attempts before transport finishes, across a restart")
        h.clock.advance(UpdateChecker.checkInterval - 1)
        restarted.checkIfDue()
        expect(h.transport.requests.count == 1, "Must not poll before 24h")
        h.clock.advance(1)
        restarted.checkIfDue()
        expect(h.transport.requests.count == 2, "Check exactly at 24h")
        h.transport.requests.last!.respond(nil, status: 500)
        restarted.stop()
        let afterFailure = h.checker(defaults: UserDefaults(suiteName: h.suite)!)
        afterFailure.start()
        expect(h.transport.requests.count == 2, "A failed attempt must still throttle across restarts")
        h.clock.advance(UpdateChecker.checkInterval)
        afterFailure.checkIfDue()
        expect(h.transport.requests.count == 3, "Failures become due again after 24h")
        h.transport.requests.last!.respond(nil, status: 404)
        h.clock.advance(3600)
        success(h.manual(afterFailure, body: nil, status: 404), .noReleases)
        afterFailure.stop()
        let afterManual = h.checker()
        afterManual.start()
        expect(h.scheduler.pending.count == 1 && h.scheduler.pending[0].delay == UpdateChecker.checkInterval,
               "A manual attempt must reset the automatic cadence")
        afterManual.stop()

        h.clock.advance(-10 * 365 * 24 * 60 * 60)
        let rolledBack = h.checker()
        rolledBack.start()
        expect(h.transport.requests.count == 4 && h.scheduler.pending[0].delay == UpdateChecker.checkInterval,
               "A clock rollback must cap the next wait at 24h, not ten years")
        rolledBack.stop()
        h.clock.advance(3600)
        let rollbackRestart = h.checker(defaults: UserDefaults(suiteName: h.suite)!)
        rollbackRestart.start()
        expect(h.scheduler.pending[0].delay == UpdateChecker.checkInterval - 3600, "Persist the corrected clock anchor across restart")
        h.clock.advance(UpdateChecker.checkInterval - 3600)
        rollbackRestart.checkIfDue()
        expect(h.transport.requests.count == 5, "Clock rollback must still become due")
        h.transport.requests.last!.respond(nil, status: 404)
        h.clock.advance(5 * UpdateChecker.checkInterval)
        rollbackRestart.checkIfDue(); rollbackRestart.checkIfDue()
        expect(h.transport.requests.count == 6, "A forward clock jump should produce one request, not catch-up polling")
        rollbackRestart.stop()
    }

    private static func schedulingAndStop() {
        let h = Harness(), checker = h.checker()
        var notices = 0
        checker.onAvailableUpdate = { _ in notices += 1 }
        checker.start()
        h.transport.requests[0].respond(release())
        expect(notices == 1, "Automatic success should deliver an update")
        expect(h.scheduler.pending.count == 1, "Completion must cancel the request watchdog")
        let timer = h.scheduler.pending[0]
        expect(timer.delay == UpdateChecker.checkInterval, "Recurring timer must be 24h")
        h.clock.advance(timer.delay)
        timer.fire()
        expect(h.transport.requests.count == 2, "The timer must trigger the next request without activation")
        let queuedTimer = h.scheduler.pending.first { $0.delay == UpdateChecker.checkInterval }!
        checker.stop()
        expect(h.scheduler.pending.isEmpty, "Stop must cancel timers/watchdog")
        h.transport.requests[1].respond(release("v2.0.0"))
        expect(notices == 1, "A stopped automatic request must ignore a late completion")
        h.clock.advance(UpdateChecker.checkInterval)
        queuedTimer.fire(evenIfCancelled: true)
        expect(h.transport.requests.count == 2, "A timer already queued at cancellation must not restart automatic work")
        checker.checkIfDue()
        expect(h.transport.requests.count == 3, "Explicit checkIfDue also works without start")
        checker.stop()
    }

    private static func coalescing() {
        let h = Harness(), checker = h.checker()
        var manual: [UpdateCheckResult] = [], notices = 0
        checker.onAvailableUpdate = { _ in notices += 1 }
        checker.start()
        for _ in 0..<2 {
            checker.checkManually {
                expect(Thread.isMainThread, "Background transport must deliver manual callbacks on main")
                manual.append(try! $0.get())
            }
        }
        checker.checkIfDue()
        expect(h.transport.requests.count == 1, "Manual and automatic callers must share one request")
        let request = h.transport.requests[0]
        DispatchQueue.global().async { request.respond(release()) }
        waitUntil { manual.count == 2 }
        expect(notices == 0, "A joined manual result owns presentation; no duplicate automatic alert")
        expect(manual[0] == manual[1], "Every coalesced manual caller must get the same result")
        request.respond(release("v9.0.0"))
        expect(manual.count == 2 && notices == 0, "Duplicate/stale transport completion must be ignored")

        var offMainResult: UpdateCheckResult?
        DispatchQueue.global().async {
            checker.checkManually {
                expect(Thread.isMainThread, "Background manual entry must deliver on main")
                offMainResult = try! $0.get()
            }
        }
        waitUntil { h.transport.requests.count == 2 }
        checker.stop()
        expect(!h.transport.requests[1].cancelled, "Stop must preserve an in-flight manual completion")
        h.transport.requests[1].respond(release())
        expect(offMainResult != nil && notices == 0, "A manual result survives stop without an automatic notification")

        h.clock.advance(UpdateChecker.checkInterval)
        checker.onAvailableUpdate = { _ in
            expect(Thread.isMainThread, "Background transport must deliver automatic callbacks on main")
            notices += 1
        }
        checker.checkIfDue()
        let automatic = h.transport.requests.last!
        DispatchQueue.global().async { automatic.respond(release()) }
        waitUntil { notices == 1 }
    }

    private static func notificationDedupe() {
        let h = Harness(), checker = h.checker()
        var notices: [AvailableUpdate] = []
        checker.onAvailableUpdate = { notices.append($0) }
        checker.start()
        h.transport.requests.last!.respond(release())
        h.clock.advance(UpdateChecker.checkInterval)
        checker.checkIfDue()
        h.transport.requests.last!.respond(release())
        expect(notices.count == 2, "Unconfirmed UI scheduling must not permanently mark a version notified")
        checker.markNotified(notices[0])
        checker.stop()
        let restarted = h.checker(defaults: UserDefaults(suiteName: h.suite)!)
        restarted.onAvailableUpdate = { notices.append($0) }
        h.clock.advance(UpdateChecker.checkInterval)
        restarted.start()
        h.transport.requests.last!.respond(release("v1.1.0+rebuilt"))
        expect(notices.count == 2, "Notified SemVer must remain suppressed across restarts/build metadata")
        _ = available(h.manual(restarted))
        expect(notices.count == 2, "Manual checks still return an already notified update without a second callback")
        let newer = available(h.manual(restarted, body: release("v1.2.0")))
        restarted.markNotified(newer)
        restarted.markNotified(notices[0])
        h.clock.advance(UpdateChecker.checkInterval)
        restarted.checkIfDue()
        h.transport.requests.last!.respond(release("v1.2.0"))
        expect(notices.count == 2, "Out-of-order UI confirmations must not downgrade the notified version")
        h.clock.advance(UpdateChecker.checkInterval)
        restarted.checkIfDue()
        h.transport.requests.last!.respond(release("v1.10.0"))
        expect(notices.count == 3 && notices.last?.version == "1.10.0", "A genuinely newer stable version must notify again")
        restarted.markNotified(notices.last!)
        h.clock.advance(UpdateChecker.checkInterval)
        restarted.checkIfDue()
        h.transport.requests.last!.respond(release("v1.3.0"))
        expect(notices.count == 3, "An older release must not re-notify after a repository rollback")
        restarted.stop()

        let custom = h.checker(repository: URL(string: "https://github.com/Fixture/Other")!)
        custom.start()
        expect(h.transport.requests.last!.request.url!.path == "/repos/Fixture/Other/releases/latest", "Persist cadence separately for configured repositories")
        custom.stop()
    }

    private static func timeouts() {
        let h = Harness(), checker = h.checker(timeout: 999)
        var results: [Result<UpdateCheckResult, Error>] = []
        checker.checkManually { results.append($0) }
        checker.checkManually { results.append($0) }
        expect(h.transport.requests.count == 1 && h.transport.requests[0].request.timeoutInterval == 60, "Clamp timeout and coalesce manual requests")
        let oldRequest = h.transport.requests[0]
        h.scheduler.pending[0].fire()
        expect(results.count == 2 && oldRequest.cancelled, "Watchdog must finish all waiters and cancel transport")
        for result in results {
            expectError(result, "A transport that never completes must time out") { if case .timedOut = $0 { return true }; return false }
        }
        oldRequest.respond(release())
        expect(results.count == 2, "A timed-out request cannot complete twice")
        checker.checkManually { results.append($0) }
        oldRequest.respond(release("v9.0.0"))
        expect(results.count == 2, "An old response must not complete a newer flight")
        h.transport.requests[1].respond(nil, status: 404)
        expect(results.count == 3, "Manual retry after timeout must work")
        success(results.last!, .noReleases)
        for (timeout, expected) in [(Double.nan, 30.0), (-1.0, 1.0), (5.0, 5.0)] {
            let bounded = h.checker(timeout: timeout)
            success(h.manual(bounded, body: nil, status: 404), .noReleases)
            expect(h.transport.requests.last!.request.timeoutInterval == expected, "Timeout configuration must remain finite and bounded")
        }

        // A synchronous transport must not leak its cancellation handle or watchdog.
        var cancelled = false, completed = false
        let synchronous = UpdateChecker(currentVersion: "1.0.0", defaults: h.defaults, clock: { h.clock.now }, transport: { request, completion in
            completion(nil, HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil), nil)
            return { cancelled = true }
        }, scheduler: h.scheduler.schedule)
        synchronous.checkManually { success($0, .noReleases); completed = true }
        expect(completed && cancelled && h.scheduler.pending.isEmpty, "Synchronous completion must clean up request and timeout")
    }
}

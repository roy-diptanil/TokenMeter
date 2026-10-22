import Foundation

/// Strict semantic version "MAJOR.MINOR.PATCH" (optional leading "v"); anything else is rejected.
public struct SemVer: Comparable, Equatable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int
    public init(_ major: Int, _ minor: Int, _ patch: Int) { self.major = major; self.minor = minor; self.patch = patch }
    public init?(_ text: String) {
        var t = Substring(text)
        if t.hasPrefix("v") { t = t.dropFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var n: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let v = Int(p) else { return nil }
            n.append(v)
        }
        self.init(n[0], n[1], n[2])
    }
    public var description: String { "\(major).\(minor).\(patch)" }
    public static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// The release version and commit the running app was built from (embedded by build.sh into Info.plist).
public struct InstalledBuild: Equatable {
    public var commit: String?     // full SHA; nil when the build was not from a git checkout
    public var dirty: Bool
    public var version: String?    // CFBundleShortVersionString (from the VERSION file); nil when unreadable
    public init(commit: String?, dirty: Bool, version: String? = nil) { self.commit = commit; self.dirty = dirty; self.version = version }

    public var short: String { commit.map { String($0.prefix(7)) } ?? "unknown" }
    public var isDev: Bool { commit == nil || dirty }
    public var semver: SemVer? { version.flatMap { SemVer($0) } }

    public static func from(info: [String: Any]?) -> InstalledBuild {
        let c = (info?["TokenMeterCommit"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valid = c.flatMap { $0.count >= 7 && $0.allSatisfy(\.isHexDigit) ? $0 : nil }
        let v = (info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return InstalledBuild(commit: valid, dirty: (info?["TokenMeterDirty"] as? String) == "true", version: v)
    }
    public static var current: InstalledBuild { from(info: Bundle.main.infoDictionary) }
}

public enum VersionInfo {
    /// `TokenMeter <version> (<short commit or 'dev'>)`; dev = unknown commit or local changes.
    public static func line(_ i: InstalledBuild) -> String {
        "TokenMeter \(i.version ?? "unknown") (\(i.isDev ? "dev" : i.short))"
    }
    /// Footer text: the version, plus the short commit only for dev/dirty builds.
    public static func footer(_ i: InstalledBuild) -> String {
        "Version \(i.version ?? "unknown")" + (i.isDev ? " (\(i.short)\(i.dirty ? "+local changes" : ""))" : "")
    }
}

public enum UpdateResult: Equatable {
    case upToDate
    case updateAvailable(String)               // newer release version, e.g. "1.0.1"
    case devBuild(latest: String)              // installed build is a dev build: informational, never nags
    case checkFailed(String)
}

public protocol UpdateCheckStorage: AnyObject {
    var lastCheck: Date? { get set }
    var lastRemoteVersion: String? { get set }
    var cacheInstalledKey: String? { get set }   // which installed build lastRemoteVersion/lastCheck were computed for
}

/// UserDefaults-backed storage (suiteless, keys prefixed "tokenmeter.").
public final class DefaultsUpdateStorage: UpdateCheckStorage {
    public init() {}
    public var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "tokenmeter.update.lastCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "tokenmeter.update.lastCheck") }
    }
    public var lastRemoteVersion: String? {
        get { UserDefaults.standard.string(forKey: "tokenmeter.update.lastRemoteVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "tokenmeter.update.lastRemoteVersion") }
    }
    public var cacheInstalledKey: String? {
        get { UserDefaults.standard.string(forKey: "tokenmeter.update.cacheInstalledKey") }
        set { UserDefaults.standard.set(newValue, forKey: "tokenmeter.update.cacheInstalledKey") }
    }
}

public struct UpdateChecker {
    public static let interval: TimeInterval = 24 * 3600
    public var remoteVersion: () async throws -> String
    public var clock: () -> Date
    public var storage: UpdateCheckStorage

    public init(remoteVersion: @escaping () async throws -> String = { try await ReleaseRemote.latestVersion() },
                clock: @escaping () -> Date = Date.init,
                storage: UpdateCheckStorage = DefaultsUpdateStorage()) {
        self.remoteVersion = remoteVersion; self.clock = clock; self.storage = storage
    }

    /// Pure: whether an automatic check is due.
    public static func shouldAutoCheck(last: Date?, now: Date, interval: TimeInterval = UpdateChecker.interval) -> Bool {
        guard let l = last else { return true }
        return now.timeIntervalSince(l) >= interval || now < l   // clock moved back: check
    }

    /// Pure: only a strictly newer RELEASE counts as an update; main moving never does.
    public static func evaluate(installed: InstalledBuild, remote: String) -> UpdateResult {
        guard let r = SemVer(remote) else { return .checkFailed("unexpected response") }
        if installed.isDev { return .devBuild(latest: r.description) }
        guard let i = installed.semver else { return .devBuild(latest: r.description) }   // unreadable own version: never nag
        return r > i ? .updateAvailable(r.description) : .upToDate
    }

    /// Always checks; records the time and remote version on success.
    public func check(installed: InstalledBuild) async -> UpdateResult {
        do {
            let v = try await remoteVersion()
            let r = Self.evaluate(installed: installed, remote: v)
            if case .checkFailed = r { return r }
            storage.lastCheck = clock(); storage.lastRemoteVersion = SemVer(v)?.description
            storage.cacheInstalledKey = Self.cacheKey(installed)
            return r
        } catch {
            return .checkFailed((error as? LocalizedError)?.errorDescription ?? "unknown error")
        }
    }

    /// Checks only when due (at most once per 24h). The attempt time is recorded even on failure so a broken network is not retried on every popover open.
    public func checkIfDue(installed: InstalledBuild) async -> UpdateResult? {
        guard Self.shouldAutoCheck(last: storage.lastCheck, now: clock()) else { return nil }
        let r = await check(installed: installed)
        if case .checkFailed = r { storage.lastCheck = clock() }
        return r
    }

    static func cacheKey(_ i: InstalledBuild) -> String { (i.version ?? "unknown") + "|" + (i.commit ?? "unknown") + (i.dirty ? "+dirty" : "") }

    /// What to show at launch, and whether a live check must run right away (ignoring the 24h throttle).
    /// A cache computed for a different installed build (app just updated/reinstalled) is discarded.
    /// "Update available" is never shown from the cache alone: it is re-verified live first.
    public func launchState(installed: InstalledBuild) -> (shown: UpdateResult?, verifyNow: Bool) {
        let key = Self.cacheKey(installed)
        if storage.cacheInstalledKey != key {
            storage.lastRemoteVersion = nil; storage.lastCheck = nil; storage.cacheInstalledKey = key
            return (nil, true)
        }
        guard let v = storage.lastRemoteVersion else { return (nil, false) }
        let r = Self.evaluate(installed: installed, remote: v)
        if case .checkFailed = r { storage.lastRemoteVersion = nil; return (nil, true) }
        if case .updateAvailable = r { return (nil, true) }
        return (r, false)
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case remote(String)
    public var errorDescription: String? { if case .remote(let m) = self { return m }; return nil }
}

/// Asks GitHub which release is newest: a HEAD request to /releases/latest, which redirects to /releases/tag/v<semver>.
/// The redirect is read, not followed. No auth, no git, no API token.
public enum ReleaseRemote {
    public static let latestURL = "https://github.com/roy-diptanil/TokenMeter/releases/latest"
    public static let timeout: TimeInterval = 15

    /// Pure: ".../releases/tag/v1.2.3" (absolute or relative, query/fragment ignored) -> "1.2.3"; anything else -> nil.
    public static func parseLocation(_ location: String?) -> String? {
        guard let loc = location, let path = URLComponents(string: loc)?.path else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, parts[parts.count - 2] == "tag", parts[parts.count - 3] == "releases",
              let v = SemVer(parts[parts.count - 1]) else { return nil }
        return v.description
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    public static func latestVersion() async throws -> String {
        guard let url = URL(string: latestURL) else { throw UpdateError.remote("bad URL") }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "HEAD"
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout; cfg.timeoutIntervalForResource = timeout
        cfg.httpCookieStorage = nil; cfg.urlCredentialStorage = nil; cfg.httpShouldSetCookies = false
        let session = URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let resp: URLResponse
        do { resp = try await session.data(for: req).1 }
        catch let e as URLError where e.code == .timedOut { throw UpdateError.remote("timed out") }
        catch { throw UpdateError.remote("network error") }
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.remote("unexpected response") }
        guard (300..<400).contains(http.statusCode) else { throw UpdateError.remote("no release found (HTTP \(http.statusCode))") }
        guard let v = parseLocation(http.value(forHTTPHeaderField: "Location")) else { throw UpdateError.remote("unexpected response") }
        return v
    }
}

public enum UpdateInstaller {
    public static let installURL = "https://raw.githubusercontent.com/roy-diptanil/TokenMeter/main/install.sh"
    public static let logRelativePath = "Library/Logs/TokenMeter-update.log"
    public static let logDisplayPath = "~/" + logRelativePath
    public static var logURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(logRelativePath) }
    /// If the app is still running this long after "Update now", the installer failed before quitting it.
    public static let stallTimeout: TimeInterval = 300
    static let path = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    /// Shell script for `/bin/bash -c`. `set -m` gives the background job its own process group and `nohup`
    /// ignores SIGHUP, so the installer survives the app being quit by the installer itself. `install` is overridable for tests.
    public static func shellCommand(install: String? = nil) -> String {
        let inner = install ?? "curl -fsSL \(installURL) | /bin/bash"
        return "mkdir -p \"$HOME/Library/Logs\"; export PATH=\"\(path)\"; set -m; "
            + "nohup /bin/bash -c \"\(inner)\" > \"$HOME/\(logRelativePath)\" 2>&1 < /dev/null &"
    }

    /// Spawns the installer detached and returns immediately (never waits).
    @discardableResult
    public static func launch() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", shellCommand()]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); return true } catch { return false }
    }
}

@MainActor
public final class UpdateModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case checking
        case result(UpdateResult)
        case updating
        case stalled
    }
    @Published public private(set) var state: State = .idle
    public let installed: InstalledBuild
    private let checker: UpdateChecker?
    private var stallTask: Task<Void, Never>?
    /// How often the background timer wakes up; the 24h throttle in `UpdateChecker.checkIfDue` decides whether a real check happens.
    nonisolated public static let pollInterval: TimeInterval = 3600
    /// Posted by Store on wake from sleep and when the network returns (so there is a single set of observers).
    nonisolated public static let systemEvent = Notification.Name("tokenmeter.systemEvent")
    private var pollTimer: Timer?
    private var eventObserver: NSObjectProtocol?
    public private(set) var pending: Task<Void, Never>?   // launch-time check (forced or ordinary), if one was scheduled

    /// For UI tests: fixed state, no checks or process spawns.
    public init(installed: InstalledBuild, state: State) { self.installed = installed; self.state = state; self.checker = nil }

    public init(installed: InstalledBuild = .current, checker: UpdateChecker = UpdateChecker(), pollInterval: TimeInterval = UpdateModel.pollInterval,
                checkAtLaunch: Bool = true) {
        self.installed = installed; self.checker = checker
        // Background cadence without the popover: hourly tick + wake/network events, all throttled to once per 24h.
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in Task { @MainActor in self?.autoCheck() } }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        eventObserver = NotificationCenter.default.addObserver(forName: UpdateModel.systemEvent, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.autoCheck() }
        }
        let launch = checker.launchState(installed: installed)
        if let r = launch.shown { state = .result(r) }
        if launch.verifyNow {
            state = .checking
            let inst = installed
            pending = Task {
                let r = await checker.check(installed: inst)
                if case .checkFailed = r { self.state = .idle } else { self.state = .result(r) }   // silent on failure
            }
        } else if checkAtLaunch {
            // Ordinary launch check (throttled to once per 24h). `pending` lets tests await it; tests that need a
            // fixed initial state pass checkAtLaunch: false.
            pending = Task { @MainActor [weak self] in await self?.autoCheck()?.value }
        }
    }

    deinit {
        pollTimer?.invalidate()
        if let o = eventObserver { NotificationCenter.default.removeObserver(o) }
    }

    public var updateAvailable: Bool { if case .result(.updateAvailable) = state { return true }; return false }
    public var busy: Bool { state == .checking || state == .updating }

    /// Non-blocking, silent on failure, at most once per 24h.
    @discardableResult
    public func autoCheck() -> Task<Void, Never>? {
        guard let checker = checker, !busy, state != .stalled else { return nil }
        let inst = installed
        return Task {
            guard let r = await checker.checkIfDue(installed: inst) else { return }
            if case .checkFailed = r { return }   // background failures stay silent
            if !self.busy { self.state = .result(r) }
        }
    }

    public func checkNow() {
        guard let checker = checker, !busy else { return }
        state = .checking
        let inst = installed
        Task { state = .result(await checker.check(installed: inst)) }
    }

    public func startUpdate() {
        guard !busy else { return }
        guard UpdateInstaller.launch() else { state = .result(.checkFailed("could not start the installer")); return }
        state = .updating
        stallTask?.cancel()
        stallTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(UpdateInstaller.stallTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.state = .stalled
        }
    }
}

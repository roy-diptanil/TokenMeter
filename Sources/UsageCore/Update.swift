import Foundation

/// The commit the running app was built from (embedded by build.sh into Info.plist).
public struct InstalledBuild: Equatable {
    public var commit: String?     // full SHA; nil when the build was not from a git checkout
    public var dirty: Bool
    public init(commit: String?, dirty: Bool) { self.commit = commit; self.dirty = dirty }

    public var short: String { commit.map { String($0.prefix(7)) } ?? "unknown" }
    public var isDev: Bool { commit == nil || dirty }

    public static func from(info: [String: Any]?) -> InstalledBuild {
        let c = (info?["TokenMeterCommit"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valid = c.flatMap { $0.count >= 7 && $0.allSatisfy(\.isHexDigit) ? $0 : nil }
        return InstalledBuild(commit: valid, dirty: (info?["TokenMeterDirty"] as? String) == "true")
    }
    public static var current: InstalledBuild { from(info: Bundle.main.infoDictionary) }
}

public enum UpdateResult: Equatable {
    case upToDate
    case updateAvailable(String)               // remote SHA
    case devBuild(remoteDiffers: Bool)         // installed commit unknown or dirty: informational, never nags
    case checkFailed(String)
}

public protocol UpdateCheckStorage: AnyObject {
    var lastCheck: Date? { get set }
    var lastRemoteSHA: String? { get set }
    var cacheInstalledCommit: String? { get set }   // which installed build lastRemoteSHA/lastCheck were computed for
}

/// UserDefaults-backed storage (suiteless, keys prefixed "tokenmeter.").
public final class DefaultsUpdateStorage: UpdateCheckStorage {
    public init() {}
    public var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: "tokenmeter.update.lastCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "tokenmeter.update.lastCheck") }
    }
    public var lastRemoteSHA: String? {
        get { UserDefaults.standard.string(forKey: "tokenmeter.update.lastRemoteSHA") }
        set { UserDefaults.standard.set(newValue, forKey: "tokenmeter.update.lastRemoteSHA") }
    }
    public var cacheInstalledCommit: String? {
        get { UserDefaults.standard.string(forKey: "tokenmeter.update.cacheInstalledCommit") }
        set { UserDefaults.standard.set(newValue, forKey: "tokenmeter.update.cacheInstalledCommit") }
    }
}

public struct UpdateChecker {
    public static let interval: TimeInterval = 24 * 3600
    public var remoteSHA: () async throws -> String
    public var clock: () -> Date
    public var storage: UpdateCheckStorage

    public init(remoteSHA: @escaping () async throws -> String = { try await GitRemote.mainSHA() },
                clock: @escaping () -> Date = Date.init,
                storage: UpdateCheckStorage = DefaultsUpdateStorage()) {
        self.remoteSHA = remoteSHA; self.clock = clock; self.storage = storage
    }

    /// Pure: whether an automatic check is due.
    public static func shouldAutoCheck(last: Date?, now: Date, interval: TimeInterval = UpdateChecker.interval) -> Bool {
        guard let l = last else { return true }
        return now.timeIntervalSince(l) >= interval || now < l   // clock moved back: check
    }

    /// Pure: SHA equality is the right test (the remote history is a single force-pushed commit).
    public static func evaluate(installed: InstalledBuild, remote: String) -> UpdateResult {
        let r = remote.lowercased()
        let differs = installed.commit != r
        if installed.isDev { return .devBuild(remoteDiffers: differs) }
        return differs ? .updateAvailable(r) : .upToDate
    }

    /// Always checks; records the time and remote SHA on success.
    public func check(installed: InstalledBuild) async -> UpdateResult {
        do {
            let sha = try await remoteSHA()
            storage.lastCheck = clock(); storage.lastRemoteSHA = sha.lowercased()
            storage.cacheInstalledCommit = Self.cacheKey(installed)
            return Self.evaluate(installed: installed, remote: sha)
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

    static func cacheKey(_ i: InstalledBuild) -> String { (i.commit ?? "unknown") + (i.dirty ? "+dirty" : "") }

    /// What to show at launch, and whether a live check must run right away (ignoring the 24h throttle).
    /// A cache computed for a different installed build (app just updated/reinstalled) is discarded.
    /// "Update available" is never shown from the cache alone: it is re-verified live first.
    public func launchState(installed: InstalledBuild) -> (shown: UpdateResult?, verifyNow: Bool) {
        let key = Self.cacheKey(installed)
        if storage.cacheInstalledCommit != key {
            storage.lastRemoteSHA = nil; storage.lastCheck = nil; storage.cacheInstalledCommit = key
            return (nil, true)
        }
        guard let sha = storage.lastRemoteSHA else { return (nil, false) }
        let r = Self.evaluate(installed: installed, remote: sha)
        if case .updateAvailable = r { return (nil, true) }
        return (r, false)
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case git(String)
    public var errorDescription: String? { if case .git(let m) = self { return m }; return nil }
}

public enum GitRemote {
    public static let repoURL = "https://github.com/roy-diptanil/TokenMeter.git"
    public static let timeout: TimeInterval = 15

    /// "<sha>\trefs/heads/main" -> sha
    public static func parseLsRemote(_ out: String) -> String? {
        guard let first = out.split(whereSeparator: \.isNewline).first,
              let sha = first.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
              sha.count == 40, sha.allSatisfy(\.isHexDigit) else { return nil }
        return sha.lowercased()
    }

    /// Public repo, no auth: prompts and credential helpers are disabled, 15s hard timeout.
    public static func mainSHA() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = ["-c", "credential.helper=", "ls-remote", repoURL, "refs/heads/main"]
                p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
                                 "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/true",
                                 "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
                let out = Pipe()
                p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(throwing: UpdateError.git("git not available")); return }
                var timedOut = false
                let kill = DispatchWorkItem { timedOut = true; if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit(); kill.cancel()
                if timedOut { cont.resume(throwing: UpdateError.git("timed out")); return }
                guard p.terminationStatus == 0 else { cont.resume(throwing: UpdateError.git("git exited with \(p.terminationStatus)")); return }
                if let sha = parseLsRemote(String(decoding: data, as: UTF8.self)) { cont.resume(returning: sha) }
                else { cont.resume(throwing: UpdateError.git("unexpected response")) }
            }
        }
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
    public private(set) var pending: Task<Void, Never>?   // launch-time live check, if one was needed

    /// For UI tests: fixed state, no checks or process spawns.
    public init(installed: InstalledBuild, state: State) { self.installed = installed; self.state = state; self.checker = nil }

    public init(installed: InstalledBuild = .current, checker: UpdateChecker = UpdateChecker()) {
        self.installed = installed; self.checker = checker
        let launch = checker.launchState(installed: installed)
        if let r = launch.shown { state = .result(r) }
        if launch.verifyNow {
            state = .checking
            let inst = installed
            pending = Task {
                let r = await checker.check(installed: inst)
                if case .checkFailed = r { self.state = .idle } else { self.state = .result(r) }   // silent on failure
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.autoCheck() }   // ordinary launch check (throttled to once per 24h)
        }
    }

    public var updateAvailable: Bool { if case .result(.updateAvailable) = state { return true }; return false }
    public var busy: Bool { state == .checking || state == .updating }

    /// Non-blocking, silent on failure, at most once per 24h.
    public func autoCheck() {
        guard let checker = checker, !busy, state != .stalled else { return }
        let inst = installed
        Task {
            guard let r = await checker.checkIfDue(installed: inst) else { return }
            if case .checkFailed = r { return }
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

import Foundation
import SwiftUI
import AppKit
import Network

public enum Fetcher {
    static func desc(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? "error" }

    /// Failure of a refresh that did not throw: cap missing, or a real per-model error (not "not available for this plan").
    public static func outcome(_ s: AccountSnapshot, _ kind: AccountKind, capStatus: Int) -> RefreshFailure? {
        if s.cap == nil || s.capError != nil { return capStatus != 0 ? RefreshFailure.fromStatus(capStatus) : RefreshFailure(reason: "Unexpected response", isAuth: false) }
        if s.modelsError != nil { return .perModel }
        return nil
    }

    /// Fetches cap + per-model usage through the account's web session. Failures keep the last good data.
    /// Accounts (by id) whose per-model spend endpoint is known not to exist; not retried until next launch.
    @MainActor static var spendUnavailable: Set<String> = []

    @MainActor
    public static func fetch(_ a: Account, previous: AccountSnapshot?, now: Date = Date()) async -> AccountSnapshot {
        var s = previous ?? AccountSnapshot()
        guard let sid = a.webStoreID.flatMap({ UUID(uuidString: $0) }) else {
            s.webLoginNeeded = true
            s.capError = desc(WebError.needsLogin); s.modelsError = s.capError
            s.refreshFailure = RefreshFailure.signInRequired.reason; s.refreshFailureIsAuth = true
            return s
        }
        s.webLoginNeeded = false
        s.refreshFailure = nil; s.refreshFailureIsAuth = nil
        var accountID: String?
        var codexCapStatus = 0
        let session = WebSession.session(for: sid, provider: a.kind.web)
        do {
            switch a.kind {
            case .claude:
                let r = try await session.fetchClaude(knownOrg: s.orgUUID, skipSpend: spendUnavailable.contains(a.id), now: now)
                s.cap = r.cap; s.capError = nil
                s.orgUUID = r.org; accountID = r.org
                if r.modelsUnavailable {
                    spendUnavailable.insert(a.id)
                    s.models = nil; s.modelsError = nil; s.modelsUnavailable = true
                } else {
                    s.modelsUnavailable = nil
                    s.models = r.models ?? s.models
                    s.modelsError = r.models == nil ? "unavailable: " + (r.modelsNote ?? "error") : nil
                }
            case .codex:
                let r = try await session.fetchCodex(now: now)
                accountID = r.accountID; codexCapStatus = r.capStatus
                s.cap = r.cap ?? s.cap
                s.capError = r.cap == nil ? "unavailable: HTTP \(r.capStatus)" : nil
                s.models = r.models ?? s.models
                s.modelsError = r.models == nil ? "unavailable: HTTP \(r.dailyStatus)" : nil
            }
            if let f = outcome(s, a.kind, capStatus: codexCapStatus) { s.refreshFailure = f.reason; s.refreshFailureIsAuth = f.isAuth }
            if s.capError == nil { s.capUpdated = now }
            if s.modelsError == nil { s.modelsUpdated = now }
        } catch {
            let f = RefreshFailure.classify(error)
            s.refreshFailure = f.reason; s.refreshFailureIsAuth = f.isAuth
            switch error {
            case WebError.needsLogin, WebError.orgMismatch:
                s.webLoginNeeded = true; s.capError = desc(error)
            default:
                s.capError = "unavailable: " + desc(error)
            }
            s.modelsError = s.capError
        }
        if let id = accountID, !id.isEmpty { s.idHint = String(id.suffix(4)); s.idKey = sha256Hex(id, prefix: 12) }
        return s
    }
}

/// Persistence for the per-account window choice: one dictionary under "tokenmeter.windowSelections".
public enum WindowSelections {
    static let key = "tokenmeter.windowSelections"
    /// Unknown or malformed stored values are dropped (they fall back to .d7).
    public static func load(from d: UserDefaults) -> [String: UsageWindow] {
        guard let raw = d.dictionary(forKey: key) as? [String: String] else { return [:] }
        return raw.compactMapValues { UsageWindow(rawValue: $0) }
    }
    public static func save(_ sel: [String: UsageWindow], to d: UserDefaults) {
        d.set(sel.mapValues(\.rawValue), forKey: key)
    }
}

/// Remembers the previous network-path state across handler calls (handler runs on one serial queue).
final class NSLockedBox: @unchecked Sendable {
    private var v: Bool?
    func swap(_ n: Bool) -> Bool? { defer { v = n }; return v }
}

@MainActor
public final class Store: ObservableObject {
    @Published public var accounts: [Account] = []
    @Published public var snapshots: [String: AccountSnapshot] = [:]
    @Published public var confirmingRemoval: String?   // account id awaiting inline remove-confirm (lives here, not in view @State)
    @Published public var refreshing = false
    @Published public var refreshResult: String?      // one-line result shown for ~5s after "Refresh now"
    private var resultToken = 0
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    /// Per-account 1d/7d/MTD choice (account id -> window); missing = .d7.
    @Published public var windowSelections: [String: UsageWindow] = [:]
    /// Where selections persist (nil = nowhere, e.g. UI tests).
    public var windowDefaults: UserDefaults?
    public var persist = true
    private var timer: Timer?
    private var lastRefresh: Date?

    /// For UI tests: no registry/cache/polling.
    public init(accounts: [Account], snapshots: [String: AccountSnapshot]) { self.accounts = accounts; self.snapshots = snapshots; self.lastRefresh = Date(); self.persist = false }

    public init() {
        accounts = Registry.load()
        windowDefaults = .standard
        windowSelections = WindowSelections.load(from: .standard)
        loadCache()
        DispatchQueue.main.async { [weak self] in self?.start() }   // poll from launch, not first popover open
    }

    public func window(for a: Account) -> UsageWindow { windowSelections[a.id] ?? .d7 }

    public func setWindow(_ w: UsageWindow, for a: Account) {
        windowSelections[a.id] = w
        if let d = windowDefaults { WindowSelections.save(windowSelections, to: d) }
    }

    public func labelExists(_ kind: AccountKind, _ label: String, excluding: String? = nil) -> Bool {
        accounts.contains { $0.kind == kind && $0.id != excluding && $0.label.caseInsensitiveCompare(label) == .orderedSame }
    }

    /// Other account of the same kind resolving to the same provider account id.
    public func duplicateOf(_ a: Account) -> Account? {
        guard let k = snapshots[a.id]?.idKey else { return nil }
        return accounts.first { $0.id != a.id && $0.kind == a.kind && snapshots[$0.id]?.idKey == k }
    }

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
        Task { await refreshAll() }
        // Event-driven refreshes. All go through refreshAll(), whose `refreshing` guard prevents overlap; none opens a sign-in window.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)   // let the network come back first
                NotificationCenter.default.post(name: UpdateModel.systemEvent, object: nil)
                await self?.refreshAll()
            }
        }
        let m = NWPathMonitor()
        let last = NSLockedBox()
        m.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            if last.swap(ok) == false && ok {
                Task { @MainActor in
                    NotificationCenter.default.post(name: UpdateModel.systemEvent, object: nil)
                    await self?.refreshAll()
                }
            }
        }
        m.start(queue: DispatchQueue(label: "tokenmeter.netpath"))
        pathMonitor = m
    }

    public var maxPercent: Double? {
        accounts.compactMap { snapshots[$0.id]?.cap?.percent }.max()
    }

    public func refreshIfStale() {
        if let l = lastRefresh, Date().timeIntervalSince(l) < 60 { return }
        Task { await refreshAll() }
    }

    /// `announce`: show a one-line result for ~5 seconds afterwards (used by the "Refresh now" button).
    public func refreshAll(announce: Bool = false) async {
        if refreshing { return }
        refreshing = true
        for a in accounts { snapshots[a.id] = await Fetcher.fetch(a, previous: snapshots[a.id]) }
        lastRefresh = Date()
        refreshing = false
        saveCache()
        if announce {
            let red = accounts.filter { health($0) == .red }.count
            refreshResult = AccountHealth.refreshMessage(total: accounts.count, red: red)
            resultToken += 1; let t = resultToken
            Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if t == self.resultToken { self.refreshResult = nil } }
        }
    }

    public func refresh(_ a: Account) async {
        snapshots[a.id] = await Fetcher.fetch(a, previous: snapshots[a.id])
        saveCache()
    }

    public func health(_ a: Account) -> HealthStatus { AccountHealth.status(a, snapshots[a.id]) }

    /// Summary-row action: sign in to the first red account if its failure is auth-related, else retry it.
    public func fixFirstAttention() {
        guard let t = AccountHealth.summary(accounts: accounts, snapshots: snapshots).target else { return }
        if t.signIn { signIn(t.account) } else { Task { await refresh(t.account) } }
    }

    /// Returns an error message if the account was not created. New accounts are web sign-in only.
    @discardableResult
    public func add(kind: AccountKind, label: String) -> String? {
        let name = label.trimmingCharacters(in: .whitespaces).isEmpty ? kind.title : label.trimmingCharacters(in: .whitespaces)
        if labelExists(kind, name) { return "A \(kind.title) account labelled \"\(name)\" already exists." }
        let a = Registry.makeAccount(kind: kind, label: name)
        accounts.append(a); if persist { Registry.save(accounts) }
        signIn(a)
        return nil
    }

    /// Opens the visible sign-in window (attaching a web data store first if the account has none);
    /// it closes itself once authenticated, then refreshes that account.
    public func signIn(_ a: Account) {
        guard let i = accounts.firstIndex(where: { $0.id == a.id }) else { return }
        if accounts[i].webStoreID == nil {
            accounts[i].webStoreID = UUID().uuidString
            if persist { Registry.save(accounts) }
        }
        guard let id = accounts[i].webStoreID.flatMap({ UUID(uuidString: $0) }) else { return }
        WebSession.session(for: id, provider: a.kind.web).showSignIn { [weak self] ok in
            guard ok else { return }
            Task { @MainActor in await self?.refresh(a) }
        }
    }

    @discardableResult
    public func rename(_ a: Account, to name: String) -> Bool {
        guard let i = accounts.firstIndex(of: a), !name.isEmpty, !labelExists(a.kind, name, excluding: a.id) else { return false }
        accounts[i].label = name; if persist { Registry.save(accounts) }
        return true
    }

    /// Removes registry entry, cached snapshot and the web data store.
    public func remove(_ a: Account) {
        confirmingRemoval = nil
        accounts = Registry.removing(a.id, from: accounts)
        snapshots[a.id] = nil
        if windowSelections.removeValue(forKey: a.id) != nil, let d = windowDefaults { WindowSelections.save(windowSelections, to: d) }
        if persist { Registry.save(accounts); saveCache() }
        if persist, let w = a.webStoreID, let u = UUID(uuidString: w),
           !accounts.contains(where: { $0.webStoreID == w }) {
            Task { await WebSession.removeStore(u) }
        }
    }

    private static var coder: (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }
    func loadCache() {
        guard let d = try? Data(contentsOf: AppPaths.cacheFile),
              let s = try? Self.coder.1.decode([String: AccountSnapshot].self, from: d) else { return }
        snapshots = s
    }
    func saveCache() {
        guard persist else { return }
        try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
        if let d = try? Self.coder.0.encode(snapshots) {
            try? d.write(to: AppPaths.cacheFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.cacheFile.path)
        }
    }
}

import Foundation

public enum HealthStatus: String, Equatable {
    case green, red
}

/// Why the last refresh failed, and whether signing in again can fix it.
public struct RefreshFailure: Equatable {
    public var reason: String
    public var isAuth: Bool
    public init(reason: String, isAuth: Bool) { self.reason = reason; self.isAuth = isAuth }

    public static let signInRequired = RefreshFailure(reason: "Sign in required", isAuth: true)
    public static let perModel = RefreshFailure(reason: "Per-model data unavailable", isAuth: false)

    /// Short human reason for a thrown refresh error (never includes tokens, URLs or bodies).
    public static func classify(_ e: Error) -> RefreshFailure {
        switch e {
        case WebError.needsLogin: return .signInRequired
        case WebError.orgMismatch: return RefreshFailure(reason: "Web session is a different account", isAuth: true)
        case WebError.cloudflare: return RefreshFailure(reason: "Blocked by Cloudflare challenge", isAuth: true)
        case WebError.http(let c) where c == 401 || c == 403: return .signInRequired
        case WebError.http(let c): return RefreshFailure(reason: c == 404 || c == 410 ? "Endpoint changed (HTTP \(c))" : "HTTP \(c)", isAuth: false)
        case WebError.parse: return RefreshFailure(reason: "Endpoint changed", isAuth: false)
        case WebError.loadFailed: return RefreshFailure(reason: "Network error", isAuth: false)
        case let u as URLError where u.code == .timedOut: return RefreshFailure(reason: "Timed out", isAuth: false)
        case is URLError: return RefreshFailure(reason: "Network error", isAuth: false)
        default: return RefreshFailure(reason: (e as? LocalizedError)?.errorDescription ?? "Refresh failed", isAuth: false)
        }
    }

    /// Reason for a non-throwing "unavailable: HTTP n" style message.
    public static func fromStatus(_ status: Int) -> RefreshFailure {
        classify(WebError.http(status))
    }
}

/// Per-account health: red = the most recent refresh failed (or never loaded and not signed in), green = it succeeded.
public enum AccountHealth {
    /// Most recent successful sync (cap or per-model).
    public static func lastSync(_ s: AccountSnapshot?) -> Date? {
        [s?.capUpdated, s?.modelsUpdated].compactMap { $0 }.max()
    }

    public static func failure(_ a: Account, _ s: AccountSnapshot?) -> RefreshFailure? {
        if let r = s?.refreshFailure { return RefreshFailure(reason: r, isAuth: s?.refreshFailureIsAuth ?? false) }
        if s?.webLoginNeeded == true || (a.webStoreID == nil && s?.cap == nil) { return .signInRequired }
        return nil
    }

    public static func status(_ a: Account, _ s: AccountSnapshot?) -> HealthStatus {
        failure(a, s) == nil ? .green : .red
    }

    /// "<reason> · last synced 3h ago" (card line for a red account).
    public static func reasonLine(_ f: RefreshFailure, lastSync: Date?, now: Date = Date()) -> String {
        f.reason + (lastSync.map { " · last synced \(formatAgo($0, now: now))" } ?? "")
    }

    /// Tooltip text for the status dot.
    public static func detail(_ a: Account, _ s: AccountSnapshot?, now: Date = Date()) -> String {
        let ago = lastSync(s).map { "last synced " + formatAgo($0, now: now) } ?? "never synced"
        if let f = failure(a, s) { return "Last refresh failed: \(f.reason) · \(ago)" }
        return "OK · \(ago)"
    }

    public struct Summary: Equatable {
        public var total: Int
        public var red: [Account]
        public var attention: Int { red.count }
        public var text: String { "\(attention) of \(total) accounts need attention" }
        public var firstAuth: Bool
        /// The first red account; the button signs in when its failure is auth-related, else retries.
        public var target: (account: Account, signIn: Bool)? { red.first.map { ($0, firstAuth) } }
        public static func == (l: Summary, r: Summary) -> Bool { l.total == r.total && l.red == r.red && l.firstAuth == r.firstAuth }
    }

    public static func summary(accounts: [Account], snapshots: [String: AccountSnapshot]) -> Summary {
        let red = accounts.filter { status($0, snapshots[$0.id]) == .red }
        return Summary(total: accounts.count, red: red, firstAuth: red.first.flatMap { failure($0, snapshots[$0.id])?.isAuth } ?? false)
    }

    /// One-line result shown after "Refresh now".
    public static func refreshMessage(total: Int, red: Int) -> String {
        if total == 0 { return "No accounts" }
        if red == 0 { return total == 1 ? "Account OK" : "All \(total) accounts OK" }
        return "\(red) of \(total) \(red == 1 ? "needs" : "need") attention"
    }
}

extension MenuLabelLogic {
    /// Same as `build`, plus a trailing red "!" segment whenever any account is red (amber alone adds nothing).
    public static func buildWithAlert(accounts: [Account], snapshots: [String: AccountSnapshot], limit: Int = 2) -> [LabelSegment] {
        var segs = build(accounts: accounts, snapshots: snapshots, limit: limit)
        if accounts.contains(where: { AccountHealth.status($0, snapshots[$0.id]) == .red }) {
            segs.append(LabelSegment(text: "!", remaining: 0, level: .red, isAlert: true))
        }
        return segs
    }
}

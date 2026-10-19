import Foundation
import CryptoKit

public enum AccountKind: String, Codable, CaseIterable {
    case claude, codex
    public var title: String { self == .claude ? "Claude" : "Codex" }
    public var vendor: String { self == .claude ? "Anthropic" : "OpenAI" }
}

public struct Account: Codable, Identifiable, Equatable {
    public var id: String
    public var kind: AccountKind
    public var label: String
    public var webStoreID: String?     // web session data store (claude.ai / chatgpt.com); nil = not signed in yet
    public init(id: String = UUID().uuidString, kind: AccountKind, label: String, webStoreID: String? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.webStoreID = webStoreID
    }
}

public struct UsageBar: Codable, Equatable {
    public var name: String
    public var percent: Double
    public var resetsAt: Date?
    public init(name: String, percent: Double, resetsAt: Date? = nil) {
        self.name = name; self.percent = percent; self.resetsAt = resetsAt
    }
}

public struct CapSnapshot: Codable, Equatable {
    public var plan: String?
    public var used: Double?
    public var limit: Double?
    public var percent: Double?
    public var severity: String?
    public var resetAt: Date?
    public var unit: String?           // "usd" | "credit"
    public var bars: [UsageBar] = []
    public var balance: Double?
    public var windowLabel: String?    // e.g. "weekly"; set when the headline is a rate-limit window (optional in old caches)
    public init() {}
}

public struct ModelRow: Codable, Equatable {
    public var name: String
    public var amount: Double
    public var share: Double           // 0...100
    public init(name: String, amount: Double, share: Double) { self.name = name; self.amount = amount; self.share = share }
}

public enum UsageWindow: String, CaseIterable, Identifiable {
    case d1 = "1d", d7 = "7d", mtd = "MTD"
    public var id: String { rawValue }
}

public struct ModelBreakdown: Codable, Equatable {
    public var d1: [ModelRow] = []
    public var d7: [ModelRow] = []
    public var mtd: [ModelRow] = []
    public var unit: String = "usd"     // "usd" | "units"
    public init() {}
    public func rows(_ w: UsageWindow) -> [ModelRow] {
        switch w { case .d1: return d1; case .d7: return d7; case .mtd: return mtd }
    }
}

public struct AccountSnapshot: Codable, Equatable {
    public var cap: CapSnapshot?
    public var capUpdated: Date?
    public var capError: String?
    public var models: ModelBreakdown?
    public var modelsUpdated: Date?
    public var modelsError: String?
    public var webLoginNeeded: Bool = false
    public var orgUUID: String?
    public var modelsUnavailable: Bool?   // per-model spend endpoint not offered for this plan (optional in old caches)
    public var refreshFailure: String?        // reason the most recent refresh failed; nil = it succeeded (optional in old caches)
    public var refreshFailureIsAuth: Bool?
    public var idHint: String?   // last 4 chars of the provider account id (non-secret)
    public var idKey: String?    // short hash of the account id, to detect duplicate accounts
    public init() {}
}

public func sha256Hex(_ s: String, prefix: Int) -> String {
    String(SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(prefix))
}

// MARK: JSON helpers (all access defensive)

public func jsonAny(_ d: Data) -> Any? { try? JSONSerialization.jsonObject(with: d) }

public func asDouble(_ v: Any?) -> Double? {
    if let n = v as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        return n.doubleValue
    }
    if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
    return nil
}

public func asDate(_ v: Any?) -> Date? {
    if let s = v as? String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        if let n = Double(s) { return epoch(n) }
        return nil
    }
    if let n = asDouble(v) { return epoch(n) }
    return nil
}
/// Epoch seconds or milliseconds.
private func epoch(_ n: Double) -> Date { Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }

extension StringProtocol {
    public var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension Dictionary where Key == String, Value == Any {
    public func dict(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    public func arr(_ k: String) -> [Any]? { self[k] as? [Any] }
    public func str(_ k: String) -> String? { self[k] as? String }
    public func num(_ k: String) -> Double? { asDouble(self[k]) }
}

// MARK: Dates / formatting

public enum DateUtil {
    public static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c }()
    public static func day(_ d: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    public static func monthPrefix(_ d: Date) -> String { String(day(d).prefix(7)) }
    public static func addDays(_ d: Date, _ n: Int) -> Date { utc.date(byAdding: .day, value: n, to: d) ?? d }
    public static func firstOfMonth(_ now: Date) -> Date { utc.date(from: utc.dateComponents([.year, .month], from: now)) ?? now }
    public static func nextMonthStart(_ now: Date) -> Date { utc.date(byAdding: .month, value: 1, to: firstOfMonth(now)) ?? now }
}

public func formatCountdown(to target: Date, from now: Date = Date()) -> String {
    let s = Int(target.timeIntervalSince(now))
    if s <= 0 { return "now" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(max(m, 1))m"
}

public func formatMoney(_ v: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency; f.currencyCode = "USD"; f.locale = Locale(identifier: "en_US")
    return f.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
}

public func formatPercent(_ p: Double) -> String { "\(Int(p.rounded()))%" }

public func formatAgo(_ d: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(d))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}

// MARK: Aggregation shared by Claude + Codex

public enum Aggregator {
    public struct Item { public var day: String; public var name: String; public var value: Double
        public init(day: String, name: String, value: Double) { self.day = day; self.name = name; self.value = value } }

    public static func rows(_ items: [Item], days: Set<String>) -> [ModelRow] {
        var sums: [String: Double] = [:]
        for i in items where days.contains(i.day) { sums[i.name, default: 0] += i.value }
        let total = sums.values.filter { $0 > 0 }.reduce(0, +)
        return sums.filter { $0.value > 0 }
            .map { ModelRow(name: $0.key, amount: $0.value, share: total > 0 ? $0.value / total * 100 : 0) }
            .sorted { $0.amount > $1.amount }
    }

    /// Per-window rows; each window is the set of "yyyy-MM-dd" days it covers.
    public static func breakdown(_ items: [Item], unit: String, d1: Set<String>, d7: Set<String>, mtd: Set<String>) -> ModelBreakdown {
        var b = ModelBreakdown(); b.unit = unit
        b.d1 = rows(items, days: d1); b.d7 = rows(items, days: d7); b.mtd = rows(items, days: mtd)
        return b
    }
}

import Foundation

public enum ClaudeParser {
    public static func prettify(_ key: String) -> String {
        let toks = key.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        var out: [String] = []
        var prevNumeric = false
        for t in toks {
            let numeric = !t.isEmpty && t.allSatisfy { $0.isNumber }
            if numeric && prevNumeric && !out.isEmpty { out[out.count - 1] += "." + t }
            else { out.append(numeric ? t : t.capitalizedFirst) }
            prevNumeric = numeric
        }
        return out.joined(separator: " ")
    }

    private static func minor(_ o: [String: Any]?) -> Double? {
        guard let o = o, let m = o.num("amount_minor") else { return nil }
        let exp = o.num("exponent") ?? 2
        return m / pow(10, exp)
    }

    /// Known rate-limit window keys, in tie-break priority order. Other keys are ignored.
    static let windowKeys: [(key: String, label: String, bar: String)] = [
        ("five_hour", "5-hour", "5-hour"), ("seven_day", "weekly", "Weekly"),
        ("seven_day_opus", "weekly Opus", "Weekly Opus"), ("seven_day_sonnet", "weekly Sonnet", "Weekly Sonnet"),
    ]

    public static func parseUsage(_ data: Data, now: Date = Date()) -> CapSnapshot? {
        guard let root = jsonAny(data) as? [String: Any] else { return nil }
        var c = CapSnapshot()
        c.unit = "usd"
        c.resetAt = DateUtil.nextMonthStart(now)
        if let s = root.dict("spend") {
            c.used = minor(s.dict("used"))
            c.limit = minor(s.dict("limit"))
            c.percent = s.num("percent")
            if c.percent == nil, let u = c.used, let l = c.limit, l > 0 { c.percent = u / l * 100 }
            c.severity = s.str("severity")
        }
        // Rate-limit windows (personal plans; null on enterprise). Order = tie-break priority.
        struct Win { var label: String; var barName: String; var percent: Double; var reset: Date? }
        var wins: [Win] = []
        for w in windowKeys {
            guard let d = root[w.key] as? [String: Any],
                  let p = d.num("utilization") ?? d.num("percent") ?? d.num("used_percent"), p.isFinite else { continue }
            wins.append(Win(label: w.label, barName: w.bar, percent: p, reset: asDate(d["resets_at"] ?? d["reset_at"])))
        }
        let hasSpendCap = (c.limit ?? 0) > 0
        var head: Win?
        if !hasSpendCap, !wins.isEmpty {
            var h = wins[0]
            for w in wins.dropFirst() where w.percent > h.percent { h = w }
            head = h
            c.unit = nil; c.used = nil; c.limit = nil; c.severity = nil
            c.percent = h.percent; c.resetAt = h.reset; c.windowLabel = h.label
        }
        for w in wins where w.label != head?.label {
            c.bars.append(UsageBar(name: w.barName, percent: w.percent, resetsAt: w.reset))
        }
        if let e = root.dict("extra_usage"), let u = e.num("utilization"), !duplicatesHeadline(u, headline: head == nil ? c.percent : nil) {
            c.bars.append(UsageBar(name: "Extra usage", percent: u))
        }
        if c.percent == nil && c.bars.isEmpty { return nil }
        return c
    }

    /// Enterprise accounts report extra_usage.utilization equal to the spend-cap percent (e.g. 78.17 vs 78);
    /// that bar would only repeat the headline. `headline` is nil when the headline is a rate-limit window.
    static func duplicatesHeadline(_ utilization: Double, headline: Double?) -> Bool {
        guard let h = headline else { return false }
        return abs(utilization - h) <= 1.5
    }

    public static func parseSpend(_ data: Data, now: Date = Date()) -> ModelBreakdown? {
        guard let root = jsonAny(data) as? [String: Any], let series = root.arr("series") else { return nil }
        var items: [Aggregator.Item] = []
        for e in series {
            guard let d = e as? [String: Any], let day = d.str("bucket"), let key = d.str("group_key") ?? d.str("group"),
                  let cost = d.num("cost_minor_units") else { continue }
            items.append(.init(day: String(day.prefix(10)), name: prettify(key), value: cost / 100))
        }
        let today = DateUtil.day(now)
        let prefix = DateUtil.monthPrefix(now)
        return Aggregator.breakdown(
            items, unit: "usd", d1: [today],
            d7: Set((0..<7).map { DateUtil.day(DateUtil.addDays(now, -$0)) }),
            mtd: Set(items.map(\.day).filter { $0.hasPrefix(prefix) && $0 <= today }))
    }
}

/// One organization's `/usage` probe result (status + raw body, body only kept for 200).
public struct OrgUsageProbe: Equatable {
    public var id: String
    public var status: Int
    public var body: String
    public init(id: String, status: Int, body: String) { self.id = id; self.status = status; self.body = body }
}

public enum ClaudeOrgPicker {
    static let allWindowKeys = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps", "seven_day_cowork"]

    public static func shape(_ body: String) -> (spend: Bool, windows: Bool) {
        guard let j = jsonAny(Data(body.utf8)) as? [String: Any] else { return (false, false) }
        return (j["spend"] is [String: Any], allWindowKeys.contains { j[$0] is [String: Any] })
    }

    /// First org with a spend block; else first with any non-null window; else first that returned 200.
    public static func pick(_ probes: [OrgUsageProbe]) -> OrgUsageProbe? {
        let ok = probes.filter { $0.status == 200 }
        let shapes = ok.map { shape($0.body) }
        if let i = shapes.firstIndex(where: { $0.spend }) { return ok[i] }
        if let i = shapes.firstIndex(where: { $0.windows }) { return ok[i] }
        return ok.first
    }
}

import Foundation

public enum CodexParser {
    static func prettyKey(_ k: String) -> String {
        k.split(separator: "_").map { $0.capitalizedFirst }.joined(separator: " ")
    }

    static func collectBars(_ v: Any?, name: String, into bars: inout [UsageBar], depth: Int = 0, now: Date) {
        guard depth < 4, let d = v as? [String: Any] else { return }
        if let p = d.num("used_percent") ?? d.num("utilization") {
            var reset = asDate(d["reset_at"])
            if reset == nil, let s = d.num("reset_after_seconds") { reset = now.addingTimeInterval(s) }
            var title = name
            if let w = d.num("limit_window_seconds") {
                title = w >= 86400 ? "\(Int((w / 86400).rounded()))-day" : "\(Int((w / 3600).rounded()))-hour"
            }
            bars.append(UsageBar(name: title, percent: p, resetsAt: reset))
            return
        }
        for k in d.keys.sorted() { collectBars(d[k], name: prettyKey(k), into: &bars, depth: depth + 1, now: now) }
    }

    public static func windowLabel(seconds w: Double) -> String {
        switch Int(w.rounded()) {
        case 604800: return "weekly"
        case 18000: return "5-hour"
        case 86400: return "daily"
        default:
            return w >= 86400 ? "\(Int((w / 86400).rounded()))-day window" : "\(Int((w / 3600).rounded()))-hour window"
        }
    }

    public static func parseUsage(_ data: Data, now: Date = Date()) -> CapSnapshot? {
        guard let root = jsonAny(data) as? [String: Any] else { return nil }
        var c = CapSnapshot()
        c.unit = "credit"
        if let p = root.str("plan_type"), !p.isEmpty { c.plan = p.capitalizedFirst }
        if let l = root.dict("spend_control")?.dict("individual_limit") {
            c.used = l.num("used"); c.limit = l.num("limit")
            c.percent = l.num("used_percent")
            if c.percent == nil, let u = c.used, let lim = c.limit, lim > 0 { c.percent = u / lim * 100 }
            c.resetAt = asDate(l["reset_at"])
            if c.resetAt == nil, let s = l.num("reset_after_seconds") { c.resetAt = now.addingTimeInterval(s) }
        }
        var rate = root.dict("rate_limit")
        if c.percent == nil, let rl = rate {
            struct Win { var key: String; var percent: Double; var reset: Date?; var label: String? }
            var wins: [Win] = []
            for k in ["primary_window", "secondary_window"] {
                guard let w = rl.dict(k), let p = w.num("used_percent") else { continue }
                var reset = asDate(w["reset_at"])
                if reset == nil, let s = w.num("reset_after_seconds") { reset = now.addingTimeInterval(s) }
                wins.append(Win(key: k, percent: p, reset: reset, label: w.num("limit_window_seconds").map { windowLabel(seconds: $0) }))
            }
            if var head = wins.first {
                if wins.count > 1, wins[1].percent > head.percent { head = wins[1] }   // tie: primary
                c.percent = head.percent; c.resetAt = head.reset; c.windowLabel = head.label
                for w in wins where w.key != head.key {
                    c.bars.append(UsageBar(name: w.label ?? prettyKey(w.key), percent: w.percent, resetsAt: w.reset))
                }
                rate?["primary_window"] = nil; rate?["secondary_window"] = nil
            }
        }
        collectBars(rate, name: "Rate limit", into: &c.bars, now: now)
        if let b = root.dict("credits")?.dict("balance") { c.balance = b.num("amount") ?? b.num("value") }
        else if let n = root.dict("credits")?.num("balance") { c.balance = n }
        if c.percent == nil && c.bars.isEmpty && c.plan == nil { return nil }
        return c
    }

    public static func parseDaily(_ data: Data, now: Date = Date()) -> ModelBreakdown? {
        guard let root = jsonAny(data) as? [String: Any], let days = root.arr("data") else { return nil }
        var items: [Aggregator.Item] = []
        for e in days {
            guard let d = e as? [String: Any], let day = d.str("date") else { continue }
            for m in d.arr("models") ?? [] {
                guard let md = m as? [String: Any], let name = md.str("model"), let v = md.num("credits") else { continue }
                items.append(.init(day: String(day.prefix(10)), name: name, value: v))
            }
        }
        let dates = Array(Set(days.compactMap { ($0 as? [String: Any])?.str("date").map { String($0.prefix(10)) } })).sorted()
        let prefix = DateUtil.monthPrefix(now)
        return Aggregator.breakdown(
            items, unit: "units", d1: Set(dates.suffix(1)), d7: Set(dates.suffix(7)),
            mtd: Set(dates.filter { $0.hasPrefix(prefix) }))
    }
}

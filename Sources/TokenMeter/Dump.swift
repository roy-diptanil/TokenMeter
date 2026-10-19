import AppKit
import UsageCore

enum Dump {
    static func run() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            let wd = Task { try? await Task.sleep(nanoseconds: 240_000_000_000); print("timeout"); exit(2) }
            for a in Registry.load() {
                let s = await Fetcher.fetch(a, previous: nil)
                print(format(a, s))
            }
            wd.cancel()
            fflush(stdout)
            exit(0)
        }
        NSApplication.shared.run()
    }

    static func num(_ v: Double, _ unit: String) -> String { unit == "usd" ? formatMoney(v) : String(format: "%.2f", v) }

    static func format(_ a: Account, _ s: AccountSnapshot) -> String {
        var o = "== \(a.kind.rawValue) \"\(a.label)\""
        if let c = s.cap {
            o += " plan=\(c.plan ?? "?")\n"
            if let p = c.percent { o += "  cap: \(String(format: "%.1f", p))%" + (c.windowLabel.map { " of \($0) limit" } ?? "") } else { o += "  cap: n/a" }
            if let u = c.used, let l = c.limit { o += "  used \(String(format: "%.2f", u)) of \(String(format: "%.2f", l)) \(c.unit ?? "")" }
            if let sv = c.severity { o += "  severity=\(sv)" }
            if let r = c.resetAt { o += "\n  resets \(ISO8601DateFormatter().string(from: r)) (in \(formatCountdown(to: r)))" }
            if let b = c.balance { o += "\n  credit balance: \(b)" }
            for b in c.bars { o += "\n  bar \(b.name): \(String(format: "%.1f", b.percent))%" + (b.resetsAt.map { " resets \(ISO8601DateFormatter().string(from: $0)) (in \(formatCountdown(to: $0)))" } ?? "") }
            o += "\n"
        } else { o += "\n  cap: \(s.capError ?? "unavailable")\n" }
        if let m = s.models {
            for w in UsageWindow.allCases {
                o += "  models \(w.rawValue) [\(m.unit)]:"
                let rows = m.rows(w)
                if rows.isEmpty { o += " (none)" }
                for r in rows { o += "\n    \(r.name): \(num(r.amount, m.unit)) (\(formatPercent(r.share)))" }
                o += "\n"
            }
        } else if s.modelsUnavailable == true, s.modelsError == nil { o += "  models: not available for this plan\n"
        } else { o += "  models: \(s.modelsError ?? "unavailable")\n" }
        if s.models != nil, let e = s.modelsError { o += "  models note: \(e)\n" }
        o += "  health: \(AccountHealth.status(a, s).rawValue)" + (AccountHealth.failure(a, s).map { " (\($0.reason))" } ?? "") + "\n"
        return o
    }
}

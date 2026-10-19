import Foundation
import UsageCore

var failures = 0
func check(_ c: Bool, _ m: String, line: Int = #line) { if !c { failures += 1; print("FAIL line \(line): \(m)") } }
func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.001 } ?? false }

// fixed "now": 2026-10-19 12:00 UTC
let now = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!

// --- Claude usage
let usage = #"""
{"spend":{"used":{"amount_minor":123456,"currency":"USD"},"limit":{"amount_minor":200000},"percent":61.73,"severity":"warning"},
 "extra_usage":{"utilization":12.5},"five_hour":{"utilization":40,"resets_at":"2026-10-19T15:00:00Z"},"seven_day":null}
"""#
let cap = ClaudeParser.parseUsage(Data(usage.utf8), now: now)
check(near(cap?.used, 1234.56) && near(cap?.limit, 2000) && near(cap?.percent, 61.73) && cap?.severity == "warning", "claude spend")
check(cap?.bars.map(\.name) == ["5-hour", "Extra usage"], "claude bars \(String(describing: cap?.bars.map(\.name)))")
check(cap?.resetAt == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"), "reset next month")
check(ClaudeParser.parseUsage(Data("[]".utf8)) == nil, "bad usage nil")
check(ClaudeParser.parseUsage(Data(#"{"spend":{"used":{"amount_minor":50},"limit":{"amount_minor":100}}}"#.utf8))?.percent == 50, "percent fallback")

// --- prettify
check(ClaudeParser.prettify("claude_opus_5_5") == "Claude Opus 5.5", ClaudeParser.prettify("claude_opus_5_5"))
check(ClaudeParser.prettify("claude_sonnet_4") == "Claude Sonnet 4", "sonnet")
check(ClaudeParser.prettify("claude_haiku_3_5_x") == "Claude Haiku 3.5 X", "haiku")

// --- Claude spend windows (today = 2026-10-19)
func s(_ d: String, _ k: String, _ c: Int) -> String { #"{"bucket":"\#(d)","group_key":"\#(k)","cost_minor_units":\#(c),"request_count":1}"# }
let spend = "{\"currency\":\"USD\",\"series\":[" + [
    s("2026-10-01", "claude_opus_5_5", 10000), s("2026-10-12", "claude_opus_5_5", 2000),
    s("2026-10-14", "claude_sonnet_5", 500), s("2026-10-19", "claude_opus_5_5", 300), s("2026-10-19", "claude_sonnet_5", 100),
].joined(separator: ",") + "],\"totals\":[]}"
let sp = ClaudeParser.parseSpend(Data(spend.utf8), now: now)!
check(sp.d1.count == 2 && near(sp.d1[0].amount, 3.0) && sp.d1[0].name == "Claude Opus 5.5", "1d")
check(near(sp.d7.first(where: { $0.name == "Claude Opus 5.5" })?.amount, 3.0), "7d opus excludes 10/12")
check(near(sp.d7.first(where: { $0.name == "Claude Sonnet 5" })?.amount, 6.0), "7d sonnet")
check(near(sp.mtd.first?.amount, 123.0) && near(sp.mtd.map(\.share).reduce(0, +), 100), "mtd")

// --- Codex usage
let cu = #"""
{"plan_type":"pro","rate_limit":null,"credits":{"balance":{"amount":"12.5"}},
 "spend_control":{"individual_limit":{"used":"80","limit":"1000","remaining":"920","used_percent":8,"reset_at":1793000000,"reset_after_seconds":3600,"unit":"credit"}}}
"""#
let ccap = CodexParser.parseUsage(Data(cu.utf8), now: now)
check(ccap?.plan == "Pro" && near(ccap?.used, 80) && near(ccap?.limit, 1000) && near(ccap?.percent, 8) && near(ccap?.balance, 12.5), "codex cap")
check(ccap?.resetAt == Date(timeIntervalSince1970: 1793000000), "codex reset")
let rl = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":30,"limit_window_seconds":18000,"reset_after_seconds":600},"secondary_window":{"used_percent":55,"limit_window_seconds":604800}}}"#
let rcap = CodexParser.parseUsage(Data(rl.utf8), now: now)
check(near(rcap?.percent, 55) && rcap?.windowLabel == "weekly" && rcap?.bars.map(\.name) == ["5-hour"], "codex both windows (legacy fixture) \(String(describing: rcap?.bars.map(\.name)))")

// Prolite-shaped (invented fixtures): headline from rate-limit window
let futureReset = 1792946264.0
let pro1 = #"{"plan_type":"prolite","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":37,"limit_window_seconds":604800,"reset_after_seconds":500,"reset_at":1792946264},"secondary_window":null},"spend_control":{"reached":false,"individual_limit":null},"credits":{"has_credits":false,"unlimited":false,"balance":"0"}}"#
let p1 = CodexParser.parseUsage(Data(pro1.utf8), now: now)
check(near(p1?.percent, 37) && p1?.windowLabel == "weekly" && p1?.resetAt == Date(timeIntervalSince1970: futureReset)
      && p1?.used == nil && p1?.limit == nil && p1?.bars.isEmpty == true && p1?.plan == "Prolite", "prolite headline")
let pro2 = #"{"plan_type":"prolite","rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000,"reset_after_seconds":600},"secondary_window":{"used_percent":64,"limit_window_seconds":604800,"reset_at":1792946264}}}"#
let p2 = CodexParser.parseUsage(Data(pro2.utf8), now: now)
check(near(p2?.percent, 64) && p2?.windowLabel == "weekly" && p2?.bars.count == 1 && p2?.bars.first?.name == "5-hour"
      && near(p2?.bars.first?.percent, 20) && p2?.bars.first?.resetsAt == now.addingTimeInterval(600), "two windows: higher is headline")
let pro3 = #"{"plan_type":"prolite","rate_limit":{"primary_window":{"used_percent":50,"limit_window_seconds":18000,"reset_after_seconds":600},"secondary_window":{"used_percent":50,"limit_window_seconds":604800}}}"#
check(CodexParser.parseUsage(Data(pro3.utf8), now: now)?.windowLabel == "5-hour", "tie -> primary")
check(CodexParser.windowLabel(seconds: 86400) == "daily" && CodexParser.windowLabel(seconds: 10800) == "3-hour window"
      && CodexParser.windowLabel(seconds: 259200) == "3-day window", "window labels")
// Business-shaped unchanged
let biz = #"{"plan_type":"business","rate_limit":null,"spend_control":{"individual_limit":{"used":"22","limit":"100","used_percent":22,"reset_at":1792946264,"unit":"credit"}}}"#
let b1 = CodexParser.parseUsage(Data(biz.utf8), now: now)
check(near(b1?.percent, 22) && near(b1?.used, 22) && near(b1?.limit, 100) && b1?.windowLabel == nil && b1?.bars.isEmpty == true, "business unchanged")
// old cache JSON (no windowLabel) still decodes
let oldCache = #"{"plan":"Pro","percent":8,"unit":"credit","bars":[{"name":"5-hour","percent":3}]}"#
let oc = try? JSONDecoder().decode(CapSnapshot.self, from: Data(oldCache.utf8))
check(near(oc?.percent, 8) && oc?.windowLabel == nil, "old cache decodes")
if let p1 = p1, let d = try? JSONEncoder().encode(p1) { check((try? JSONDecoder().decode(CapSnapshot.self, from: d))?.windowLabel == "weekly", "windowLabel roundtrip") } else { check(false, "encode") }
// neither present
let none = CodexParser.parseUsage(Data(#"{"rate_limit":{"primary_window":null,"secondary_window":null},"spend_control":{"individual_limit":null}}"#.utf8), now: now)
check(none == nil || none?.percent == nil, "neither -> percent nil")
let none2 = CodexParser.parseUsage(Data(#"{"plan_type":"prolite","rate_limit":null}"#.utf8), now: now)
check(none2 != nil && none2?.percent == nil, "plan only -> percent nil")

// --- Codex daily
func day(_ d: String, _ m: [(String, Int)]) -> String {
    "{\"date\":\"\(d)\",\"product_surface_usage_values\":{},\"models\":[" + m.map { "{\"model\":\"\($0.0)\",\"speed\":\"standard\",\"credits\":\($0.1)}" }.joined(separator: ",") + "]}"
}
let daily = "{\"units\":\"percent\",\"group_by\":\"day\",\"data\":[" + [
    day("2026-09-25", [("gpt-a", 50)]), day("2026-10-02", [("gpt-a", 10)]), day("2026-10-10", [("gpt-b", 5)]),
    day("2026-10-17", [("gpt-a", 3), ("gpt-b", 1)]), day("2026-10-18", [("gpt-a", 2)]),
].joined(separator: ",") + "]}"
let cd = CodexParser.parseDaily(Data(daily.utf8), now: now)!
check(cd.d1.count == 1 && cd.d1[0].name == "gpt-a" && near(cd.d1[0].amount, 2), "codex 1d latest date")
check(near(cd.d7.first(where: { $0.name == "gpt-a" })?.amount, 65), "codex 7d last 7 dates (all 5)")   // all 5 dates: 50+10+3+2 = 65
check(near(cd.mtd.first(where: { $0.name == "gpt-a" })?.amount, 15), "codex mtd")
check(cd.unit == "units", "unit")
check(CodexParser.parseDaily(Data("{}".utf8)) == nil, "bad daily nil")

// --- formatting
check(formatCountdown(to: now.addingTimeInterval(12 * 86400 + 7 * 3600 + 5), from: now) == "12d 7h", "countdown")
check(formatCountdown(to: now.addingTimeInterval(3 * 3600 + 120), from: now) == "3h 2m", "countdown h")
check(formatMoney(1234.56) == "$1,234.56", formatMoney(1234.56))
check(DateUtil.day(now) == "2026-10-19", "day")

// --- duplicate-account detection
let k1 = sha256Hex("acct-synth", prefix: 12), k2 = sha256Hex("acct-synth", prefix: 12)
check(sha256Hex("abc", prefix: 8) == "ba7816bf", "sha256 abc")
check(k1 == k2 && k1 != sha256Hex("other", prefix: 12), "identity key")

// --- account removal
let ra = Account(kind: .claude, label: "A"), rb = Account(kind: .codex, label: "B", webStoreID: UUID().uuidString)
check(Registry.removing(ra.id, from: [ra, rb]).map(\.id) == [rb.id], "registry removing")
check(Registry.removing("nope", from: [ra, rb]).count == 2, "removing unknown id")
let wa = Registry.makeAccount(kind: .codex, label: "W")
check(wa.webStoreID != nil, "new accounts get a web store")
await MainActor.run {
    var snap = AccountSnapshot(); snap.idKey = "k"
    let st = Store(accounts: [ra, rb], snapshots: [ra.id: snap, rb.id: snap])
    check(st.duplicateOf(ra)?.id == nil, "different kinds are not duplicates")
    check(st.labelExists(.claude, "a"), "label exists (case-insensitive)")
    check(st.add(kind: .claude, label: "A") != nil, "dup label refused")
    st.remove(rb)
    check(st.accounts.map(\.id) == [ra.id] && st.snapshots[rb.id] == nil && st.snapshots[ra.id] != nil, "Store.remove updates accounts + snapshots")
}
// registry persistence: no re-seed after removing everything
let tmpReg = FileManager.default.temporaryDirectory.appendingPathComponent("reg-test-\(UUID().uuidString)/accounts.json")
check(Registry.load(from: tmpReg).isEmpty, "first launch starts with no accounts")
let seeded = [Account(kind: .claude, label: "A"), Account(kind: .codex, label: "B")]
Registry.save(seeded, to: tmpReg)
check(Registry.load(from: tmpReg).map(\.id) == seeded.map(\.id), "saved accounts reload")
Registry.save([seeded[1]], to: tmpReg)
check(Registry.load(from: tmpReg).map(\.id) == [seeded[1].id], "reload after remove keeps removal")
Registry.save([], to: tmpReg)
check(Registry.load(from: tmpReg).isEmpty, "empty registry is not re-seeded")
try? FileManager.default.removeItem(at: tmpReg.deletingLastPathComponent())
await MainActor.run {
    let only = Account(kind: .codex, label: "Only")   // last of its kind
    let st = Store(accounts: [only], snapshots: [only.id: AccountSnapshot()])
    st.confirmingRemoval = only.id
    check(st.confirmingRemoval == only.id, "confirm state held in Store")
    st.remove(only)
    check(st.accounts.isEmpty && st.confirmingRemoval == nil && st.snapshots.isEmpty, "remove last account clears confirm")
}
// --- menu-bar label logic
func acc(_ k: AccountKind, _ l: String) -> Account { Account(kind: k, label: l) }
func snapUsed(_ p: Double?) -> AccountSnapshot { var s = AccountSnapshot(); if let p = p { var c = CapSnapshot(); c.percent = p; s.cap = c }; return s }
func lab(_ a: [Account], _ used: [Double?]) -> [LabelSegment] {
    var m: [String: AccountSnapshot] = [:]; for (x, u) in zip(a, used) { m[x.id] = snapUsed(u) }
    return MenuLabelLogic.build(accounts: a, snapshots: m)
}
let lc = acc(.claude, "Claude"), lx = acc(.codex, "Codex"), lx2 = acc(.codex, "Work")
check(MenuLabelLogic.text(lab([lc, lx], [79, 9])) == "C 21% · X 91%", "label basic")
check(lab([lc, lx], [9, 79]).map(\.text) == ["X 21%", "C 91%"], "ordering by remaining asc")
check(lab([lc, lx], [nil, nil]).isEmpty, "no data -> icon only")
check(lab([lc, lx], [nil, 50]).map(\.text) == ["X 50%"], "one account with data")
check(lab([lc, lx, lx2], [10, 50, 90]).count == 2, "3+ accounts keep only top 2")
check(lab([lc, lx, lx2], [10, 50, 90]).map(\.text) == ["W 10%", "C 50%"], "3 accounts: two codex share kind -> label initials")
check(lab([lc, lx, lx2], [90, 50, 10]).map(\.text) == ["C 10%", "X 50%"], "3 accounts: distinct kinds in top 2")
check(lab([lc, lx], [50, 50]).map(\.text) == ["C 50%", "X 50%"], "tie keeps registry order")
check(lab([lx, lc], [50, 50]).map(\.text) == ["X 50%", "C 50%"], "tie keeps registry order 2")
check(lab([lc], [100]).map(\.text) == ["C 0%"] && lab([lc], [100])[0].level == .red, "100% used")
check(lab([lc], [0]).map(\.text) == ["C 100%"] && lab([lc], [0])[0].level == .normal, "0% used")
check(lab([lc], [130]).map(\.text) == ["C 0%"], "over 100 clamps")
check(lab([lc], [-5]).map(\.text) == ["C 100%"], "negative clamps")
check(MenuLabelLogic.level(remaining: 10) == .red && MenuLabelLogic.level(remaining: 10.1) == .amber
      && MenuLabelLogic.level(remaining: 25) == .amber && MenuLabelLogic.level(remaining: 25.1) == .normal, "level thresholds")
check(lab([lx, lx2], [60, 20]).map(\.text) == ["C 40%", "W 80%"], "same kind: label initials")
check(lab([lx, acc(.codex, "Codex 2")], [60, 20]).map(\.text) == ["X1 40%", "X2 80%"], "same kind same initial -> digits")
check((lab([lc, lx], [79.4, 9]).map(\.text).joined(separator: " · ")).count <= 14, "compact")
// Claude web usage has the same shape as the OAuth one (reused parser); Codex web result parsing
let wcap = ClaudeParser.parseUsage(Data(#"{"five_hour":null,"seven_day":null,"extra_usage":{"utilization":71.6},"spend":{"used":{"amount_minor":143210,"exponent":2},"limit":{"amount_minor":200000,"exponent":2},"percent":72,"severity":"warning"}}"#.utf8), now: now)
check(near(wcap?.used, 1432.10) && near(wcap?.limit, 2000) && wcap?.bars.isEmpty == true, "claude web usage (extra_usage 71.6 duplicates spend headline 72 -> dropped)")

// --- Claude personal-plan windows (invented fixtures)
let pa = ClaudeParser.parseUsage(Data(#"{"five_hour":{"utilization":37,"resets_at":"2026-10-20T01:00:00.123456+00:00"},"seven_day":{"utilization":12,"resets_at":"2026-10-24T00:00:00+00:00"},"seven_day_opus":null,"spend":null,"extra_usage":null,"seven_day_cowork":null}"#.utf8), now: now)
check(near(pa?.percent, 37) && pa?.windowLabel == "5-hour" && pa?.unit == nil && pa?.used == nil && pa?.limit == nil, "personal (a) headline")
check(pa?.resetAt != nil && abs(pa!.resetAt!.timeIntervalSince(ISO8601DateFormatter().date(from: "2026-10-20T01:00:00Z")!)) < 1, "personal (a) reset fractional")
check(pa?.bars.map(\.name) == ["Weekly"] && near(pa?.bars.first?.percent, 12) && pa?.bars.first?.resetsAt != nil, "personal (a) bars")
let pb = ClaudeParser.parseUsage(Data(#"{"five_hour":{"utilization":5,"resets_at":"2026-10-19T15:00:00Z"},"seven_day":{"utilization":64,"resets_at":"2026-10-24T00:00:00Z"},"seven_day_sonnet":{"utilization":30,"resets_at":"2026-10-24T00:00:00Z"},"spend":null}"#.utf8), now: now)
check(near(pb?.percent, 64) && pb?.windowLabel == "weekly" && pb?.bars.map(\.name) == ["5-hour", "Weekly Sonnet"]
      && near(pb?.bars[0].percent, 5) && near(pb?.bars[1].percent, 30), "personal (b) weekly headline")
let tie = ClaudeParser.parseUsage(Data(#"{"five_hour":{"utilization":20},"seven_day":{"utilization":20}}"#.utf8), now: now)
check(tie?.windowLabel == "5-hour", "window tie -> five_hour")
// (c) enterprise unchanged
check(cap?.windowLabel == nil && cap?.unit == "usd" && near(cap?.percent, 61.73) && cap?.bars.map(\.name) == ["5-hour", "Extra usage"], "enterprise (c) unchanged")
check(wcap?.windowLabel == nil && wcap?.unit == "usd" && wcap?.resetAt == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"), "enterprise web unchanged")
// (d) spend + windows
let pd = ClaudeParser.parseUsage(Data(#"{"spend":{"used":{"amount_minor":5000},"limit":{"amount_minor":10000},"percent":50},"five_hour":{"utilization":90,"resets_at":"2026-10-19T15:00:00Z"},"seven_day":{"utilization":10},"extra_usage":{"utilization":3}}"#.utf8), now: now)
check(near(pd?.percent, 50) && pd?.windowLabel == nil && near(pd?.limit, 100) && pd?.bars.map(\.name) == ["5-hour", "Weekly", "Extra usage"], "spend+windows (d)")
// (e) tolerant parsing
let pe = ClaudeParser.parseUsage(Data(#"{"five_hour":{"utilization":"42.5","resets_at":1792946264},"seven_day":{"utilization":10},"seven_day_opus":{"resets_at":"x"},"weird_key":{"utilization":99}}"#.utf8), now: now)
check(near(pe?.percent, 42.5) && pe?.resetAt == Date(timeIntervalSince1970: 1792946264) && pe?.bars.map(\.name) == ["Weekly"], "tolerant (e) string util + epoch")
let pe2 = ClaudeParser.parseUsage(Data(#"{"seven_day":{"utilization":70}}"#.utf8), now: now)
check(near(pe2?.percent, 70) && pe2?.resetAt == nil && pe2?.windowLabel == "weekly", "missing resets_at")
check(near(ClaudeParser.parseUsage(Data(#"{"five_hour":{"utilization":8,"resets_at":1792946264000}}"#.utf8), now: now)?.resetAt?.timeIntervalSince1970 ?? 0, 1792946264), "epoch ms")
check(formatCountdown(to: now.addingTimeInterval(2 * 3600 + 14 * 60 + 30), from: now) == "2h 14m", "5h countdown")
// old cache decodes without new snapshot field
check((try? JSONDecoder().decode(AccountSnapshot.self, from: Data(#"{"webLoginNeeded":false}"#.utf8)))?.modelsUnavailable == nil, "old snapshot decodes")
// (f) org selection
let spendBody = #"{"spend":{"percent":10,"limit":{"amount_minor":100}},"five_hour":null}"#
let winBody = #"{"spend":null,"five_hour":{"utilization":3}}"#
let emptyBody = #"{"spend":null,"five_hour":null,"seven_day":null}"#
check(ClaudeOrgPicker.pick([.init(id: "o1", status: 200, body: emptyBody), .init(id: "o2", status: 200, body: winBody)])?.id == "o2", "org: personal-only")
check(ClaudeOrgPicker.pick([.init(id: "p", status: 200, body: winBody), .init(id: "e", status: 200, body: spendBody)])?.id == "e", "org: enterprise preferred")
check(ClaudeOrgPicker.pick([.init(id: "x", status: 403, body: ""), .init(id: "o1", status: 200, body: emptyBody), .init(id: "o2", status: 200, body: "{}")])?.id == "o1", "org: none qualifies -> first 200")
check(ClaudeOrgPicker.pick([.init(id: "x", status: 404, body: "")]) == nil, "org: no 200 -> nil")

// --- Feature A: redundant "Extra usage" bar (invented numbers)
func spendJSON(_ pct: Double, extra: Double?, windows: String = "") -> Data {
    Data(("{\"spend\":{\"used\":{\"amount_minor\":1000},\"limit\":{\"amount_minor\":2000},\"percent\":\(pct)}" + windows
          + (extra.map { ",\"extra_usage\":{\"utilization\":\($0)}" } ?? "") + "}").utf8)
}
check(ClaudeParser.parseUsage(spendJSON(78, extra: 78.17), now: now)?.bars.isEmpty == true, "extra usage equal to cap -> no bar")
check(ClaudeParser.parseUsage(spendJSON(78, extra: 79.5), now: now)?.bars.isEmpty == true, "extra usage within 1.5 -> no bar")
check(ClaudeParser.parseUsage(spendJSON(78, extra: 68), now: now)?.bars.map(\.name) == ["Extra usage"], "extra usage differs by 10 -> bar kept")
check(ClaudeParser.parseUsage(spendJSON(78, extra: 79.6), now: now)?.bars.map(\.name) == ["Extra usage"], "extra usage just over 1.5 -> bar kept")
let wx = ClaudeParser.parseUsage(Data(#"{"five_hour":{"utilization":37},"seven_day":{"utilization":12},"spend":null,"extra_usage":{"utilization":37.2}}"#.utf8), now: now)
check(wx?.windowLabel == "5-hour" && wx?.bars.map(\.name) == ["Weekly", "Extra usage"], "window headline keeps extra usage bar even when equal")

// --- Feature B: update checker (invented SHAs, injected deps, no network)
let shaA = String(repeating: "a1", count: 20), shaB = String(repeating: "b2", count: 20)
final class MemStore: UpdateCheckStorage { var lastCheck: Date?; var lastRemoteSHA: String?; var cacheInstalledCommit: String? }
struct Boom: Error, LocalizedError { var errorDescription: String? { "offline" } }
func checker(_ remote: @escaping () async throws -> String, _ st: MemStore = MemStore()) -> UpdateChecker {
    UpdateChecker(remoteSHA: remote, clock: { now }, storage: st)
}
let clean = InstalledBuild(commit: shaA, dirty: false)
check(await checker({ shaA }).check(installed: clean) == .upToDate, "equal sha -> upToDate")
check(await checker({ shaB }).check(installed: clean) == .updateAvailable(shaB), "different sha -> updateAvailable")
check(await checker({ shaB }).check(installed: InstalledBuild(commit: nil, dirty: false)) == .devBuild(remoteDiffers: true), "unknown installed -> devBuild")
check(await checker({ shaA }).check(installed: InstalledBuild(commit: shaA, dirty: true)) == .devBuild(remoteDiffers: false), "dirty -> devBuild (same)")
check(await checker({ shaB }).check(installed: InstalledBuild(commit: shaA, dirty: true)) == .devBuild(remoteDiffers: true), "dirty -> devBuild (differs)")
check(await checker({ throw Boom() }).check(installed: clean) == .checkFailed("offline"), "failure -> checkFailed")
let memo = MemStore()
_ = await checker({ shaB }, memo).check(installed: clean)
check(memo.lastCheck == now && memo.lastRemoteSHA == shaB, "check records time + sha")
check(memo.cacheInstalledCommit == shaA, "check records which installed build the cache is for")
check(await checker({ shaA }, memo).checkIfDue(installed: clean) == nil, "auto check throttled right after a check")
let failMemo = MemStore()
_ = await checker({ throw Boom() }, failMemo).checkIfDue(installed: clean)
check(failMemo.lastCheck == now, "failed auto check still counts as an attempt")
check(UpdateChecker.shouldAutoCheck(last: nil, now: now), "throttle: never checked -> due")
check(!UpdateChecker.shouldAutoCheck(last: now.addingTimeInterval(-23 * 3600), now: now), "throttle: 23h -> not due")
check(UpdateChecker.shouldAutoCheck(last: now.addingTimeInterval(-24 * 3600), now: now), "throttle: 24h -> due")
check(UpdateChecker.shouldAutoCheck(last: now.addingTimeInterval(3600), now: now), "throttle: clock moved back -> due")
check(GitRemote.parseLsRemote("\(shaA)\trefs/heads/main\n") == shaA && GitRemote.parseLsRemote("") == nil
      && GitRemote.parseLsRemote("garbage\trefs/heads/main") == nil, "ls-remote parsing")
check(InstalledBuild.from(info: ["TokenMeterCommit": shaA, "TokenMeterDirty": "false"]) == clean
      && InstalledBuild.from(info: ["TokenMeterCommit": "unknown"]).commit == nil
      && InstalledBuild.from(info: ["TokenMeterCommit": shaA, "TokenMeterDirty": "true"]).dirty
      && InstalledBuild.from(info: nil).isDev && clean.short == "a1a1a1a", "installed build from Info.plist")
// launch-time cache handling
let c1 = MemStore(); c1.lastRemoteSHA = shaB; c1.lastCheck = now.addingTimeInterval(-3600); c1.cacheInstalledCommit = shaA
let ls1 = checker({ shaA }, c1).launchState(installed: clean)
check(ls1.shown == nil && ls1.verifyNow, "cached update-available is never shown; verified live")
let c2 = MemStore(); c2.lastRemoteSHA = shaA; c2.lastCheck = now.addingTimeInterval(-3600); c2.cacheInstalledCommit = shaA
let ls2 = checker({ shaA }, c2).launchState(installed: clean)
check(ls2.shown == .upToDate && !ls2.verifyNow, "cached upToDate shown instantly, no forced check")
let c3 = MemStore(); c3.lastRemoteSHA = shaB; c3.lastCheck = now.addingTimeInterval(-3600); c3.cacheInstalledCommit = shaB
let ls3 = checker({ shaA }, c3).launchState(installed: clean)
check(ls3.shown == nil && ls3.verifyNow && c3.lastRemoteSHA == nil && c3.lastCheck == nil && c3.cacheInstalledCommit == shaA, "cache for a different installed build is discarded")
let c4 = MemStore(); c4.lastRemoteSHA = shaB; c4.lastCheck = now.addingTimeInterval(-3600)   // legacy cache without installed-build key
check(checker({ shaA }, c4).launchState(installed: clean).verifyNow && c4.lastRemoteSHA == nil, "legacy cache discarded")
let c5 = MemStore(); c5.lastRemoteSHA = shaB; c5.cacheInstalledCommit = "unknown"
check(checker({ shaA }, c5).launchState(installed: InstalledBuild(commit: nil, dirty: false)).shown == .devBuild(remoteDiffers: true), "cached devBuild shown instantly")
await MainActor.run {
    // stale cache says update available, but remote now equals installed: never shows 'Update available'
    let st = MemStore(); st.lastRemoteSHA = shaB; st.lastCheck = now.addingTimeInterval(-60); st.cacheInstalledCommit = shaA
    let m = UpdateModel(installed: clean, checker: checker({ shaA }, st))
    check(m.state == .checking && !m.updateAvailable, "model: stale cache -> checking, not 'Update available'")
    Task { @MainActor in
        await m.pending?.value
        check(m.state == .result(.upToDate) && st.lastRemoteSHA == shaA, "model: live check resolves to upToDate")
    }
}
try? await Task.sleep(nanoseconds: 200_000_000)
// background check (no popover): throttle boundaries and model tick
check(await MainActor.run { UpdateModel.pollInterval } == 3600, "poll interval is hourly")
let bgNotDue = MemStore(); bgNotDue.lastCheck = now.addingTimeInterval(-24 * 3600 + 1)
check(await checker({ shaB }, bgNotDue).checkIfDue(installed: clean) == nil, "bg: 23h59m59s -> no network check")
let bgDue = MemStore(); bgDue.lastCheck = now.addingTimeInterval(-24 * 3600)
check(await checker({ shaB }, bgDue).checkIfDue(installed: clean) == .updateAvailable(shaB), "bg: exactly 24h -> checks without any popover")
check(!UpdateChecker.shouldAutoCheck(last: now.addingTimeInterval(-24 * 3600 + 1), now: now) && UpdateChecker.shouldAutoCheck(last: now.addingTimeInterval(-24 * 3600 - 1), now: now), "bg: 24h boundary")
func bgModel(lastCheck: Date, remote: @escaping () async throws -> String) async -> (UpdateModel, MemStore) {
    await MainActor.run {
        let st = MemStore(); st.lastRemoteSHA = shaA; st.lastCheck = lastCheck; st.cacheInstalledCommit = shaA
        return (UpdateModel(installed: clean, checker: checker(remote, st)), st)
    }
}
let (mDue, _) = await bgModel(lastCheck: now.addingTimeInterval(-25 * 3600)) { shaB }
await MainActor.run { check(mDue.state == .result(.upToDate), "bg model: starts upToDate from cache") }
await mDue.autoCheck()?.value
await MainActor.run { check(mDue.state == .result(.updateAvailable(shaB)), "bg model: due tick -> Update available") }
let (mNot, _) = await bgModel(lastCheck: now.addingTimeInterval(-3600)) { shaB }
await mNot.autoCheck()?.value
await MainActor.run { check(mNot.state == .result(.upToDate), "bg model: not-due tick leaves state unchanged") }
let (mFail, _) = await bgModel(lastCheck: now.addingTimeInterval(-25 * 3600)) { throw Boom() }
await mFail.autoCheck()?.value
await MainActor.run { check(mFail.state == .result(.upToDate), "bg model: failed background check is silent") }
let cmd = UpdateInstaller.shellCommand()
check(cmd.contains("https://raw.githubusercontent.com/roy-diptanil/TokenMeter/main/install.sh") && cmd.contains("| /bin/bash"), "cmd: install url")
check(cmd.contains("Library/Logs/TokenMeter-update.log") && cmd.contains("nohup") && cmd.contains("/opt/homebrew/bin")
      && cmd.contains("/usr/local/bin") && cmd.contains("PATH=") && cmd.hasSuffix("&") && cmd.contains("mkdir -p"), "cmd: log, nohup, PATH, background")

// --- Feature C: account health (two states: last refresh failed = red, succeeded = green)
let ha = Account(kind: .claude, label: "H", webStoreID: UUID().uuidString)
func hs(_ ago: TimeInterval?, login: Bool = false, fail: String? = nil, auth: Bool = false, models: TimeInterval? = nil) -> AccountSnapshot {
    var s = AccountSnapshot(); s.webLoginNeeded = login
    s.refreshFailure = fail; s.refreshFailureIsAuth = fail == nil ? nil : auth
    s.capUpdated = ago.map { now.addingTimeInterval(-$0) }; s.modelsUpdated = models.map { now.addingTimeInterval(-$0) }
    return s
}
check(AccountHealth.status(ha, hs(120)) == .green, "health: success -> green")
check(AccountHealth.status(ha, hs(7 * 86400)) == .green, "health: old data but last refresh OK -> green (no staleness state)")
check(AccountHealth.status(ha, hs(nil)) == .green && AccountHealth.status(ha, nil) == .green, "health: signed in, not loaded yet -> green")
check(AccountHealth.status(ha, hs(10, login: true)) == .red, "health: needs sign-in -> red even if recent")
check(AccountHealth.status(ha, hs(10, fail: "Network error")) == .red, "health: non-auth failure -> red")
check(AccountHealth.status(Account(kind: .codex, label: "N"), nil) == .red, "health: never signed in -> red")
check(AccountHealth.lastSync(hs(7200, models: 60)) == now.addingTimeInterval(-60), "last sync = most recent of cap/models")
check(AccountHealth.detail(ha, hs(240), now: now) == "OK · last synced 4m ago", AccountHealth.detail(ha, hs(240), now: now))
check(AccountHealth.detail(ha, hs(3 * 3600, fail: "Network error"), now: now) == "Last refresh failed: Network error · last synced 3h ago", "tooltip red")
check(AccountHealth.detail(ha, hs(5, login: true), now: now) == "Last refresh failed: Sign in required · last synced just now", AccountHealth.detail(ha, hs(5, login: true), now: now))
check(AccountHealth.reasonLine(.signInRequired, lastSync: now.addingTimeInterval(-3 * 3600), now: now) == "Sign in required · last synced 3h ago", "reason line")
check(AccountHealth.reasonLine(.perModel, lastSync: nil, now: now) == "Per-model data unavailable", "reason line without data")
// failure classification
check(RefreshFailure.classify(WebError.needsLogin) == .signInRequired && RefreshFailure.classify(WebError.http(403)).isAuth
      && RefreshFailure.classify(WebError.orgMismatch).isAuth && RefreshFailure.classify(WebError.cloudflare).isAuth, "classify: auth")
check(RefreshFailure.classify(WebError.loadFailed) == RefreshFailure(reason: "Network error", isAuth: false)
      && RefreshFailure.classify(URLError(.notConnectedToInternet)).reason == "Network error"
      && RefreshFailure.classify(URLError(.timedOut)).reason == "Timed out"
      && RefreshFailure.classify(WebError.parse).reason == "Endpoint changed"
      && RefreshFailure.classify(WebError.http(404)).reason.hasPrefix("Endpoint changed")
      && !RefreshFailure.classify(WebError.http(500)).isAuth, "classify: non-auth")
// Fetcher.outcome: partial failures
var okSnap = AccountSnapshot(); okSnap.cap = CapSnapshot(); okSnap.models = ModelBreakdown()
check(Fetcher.outcome(okSnap, .claude, capStatus: 0) == nil, "outcome: all fine")
var partial = okSnap; partial.models = nil; partial.modelsError = "unavailable: HTTP 500"
check(Fetcher.outcome(partial, .claude, capStatus: 0) == .perModel, "outcome: real per-model failure -> red 'Per-model data unavailable'")
var notOffered = okSnap; notOffered.models = nil; notOffered.modelsUnavailable = true
check(Fetcher.outcome(notOffered, .claude, capStatus: 0) == nil, "outcome: per-model not offered for plan is not a failure")
var capFail = AccountSnapshot(); capFail.capError = "unavailable: HTTP 401"
check(Fetcher.outcome(capFail, .codex, capStatus: 401)?.isAuth == true, "outcome: cap 401 -> auth")
check((try? JSONDecoder().decode(AccountSnapshot.self, from: Data(#"{"webLoginNeeded":false,"capError":"x"}"#.utf8)))?.refreshFailure == nil, "old cache decodes without failure fields")
let hb = Account(kind: .codex, label: "B", webStoreID: UUID().uuidString), hc = Account(kind: .codex, label: "C", webStoreID: UUID().uuidString)
let hsnaps = [ha.id: hs(60), hb.id: hs(3600, fail: "Network error"), hc.id: hs(60, login: true)]
let sm = AccountHealth.summary(accounts: [ha, hb, hc], snapshots: hsnaps)
check(sm.attention == 2 && sm.text == "2 of 3 accounts need attention" && sm.target?.account.id == hb.id && sm.target?.signIn == false, "summary: first red non-auth -> Retry")
let sm2 = AccountHealth.summary(accounts: [ha, hc], snapshots: hsnaps)
check(sm2.target?.account.id == hc.id && sm2.target?.signIn == true && sm2.text == "1 of 2 accounts need attention", "summary: first red auth -> Sign in")
check(AccountHealth.summary(accounts: [ha], snapshots: hsnaps).target == nil, "summary: all green -> nothing")
check(AccountHealth.refreshMessage(total: 3, red: 0) == "All 3 accounts OK" && AccountHealth.refreshMessage(total: 3, red: 1) == "1 of 3 needs attention"
      && AccountHealth.refreshMessage(total: 3, red: 2) == "2 of 3 need attention" && AccountHealth.refreshMessage(total: 1, red: 0) == "Account OK", "refresh result message")
// menu-bar '!'
func alertLab(_ a: [Account], _ used: [Double?], _ snaps: [AccountSnapshot]) -> [LabelSegment] {
    var m: [String: AccountSnapshot] = [:]
    for ((x, u), sn) in zip(zip(a, used), snaps) { var s = sn; if let u = u { var c = CapSnapshot(); c.percent = u; s.cap = c }; m[x.id] = s }
    return MenuLabelLogic.buildWithAlert(accounts: a, snapshots: m)
}
let l0 = alertLab([ha, hb], [79, 9], [hs(60), hs(60)])
check(MenuLabelLogic.text(l0) == "C 21% · X 91%" && !l0.contains(where: \.isAlert), "label: no red -> no !")
let l1 = alertLab([ha, hb], [79, 9], [hs(60), hs(60, login: true)])
check(MenuLabelLogic.text(l1) == "C 21% · X 91% !" && l1.last?.isAlert == true && l1.last?.level == .red && l1.count == 3, "label: red -> red ! after percentages")
let l2 = alertLab([ha, hb], [79, 9], [hs(60), hs(60, fail: "Timed out")])
check(l2.last?.isAlert == true && l2.last?.level == .red && MenuLabelLogic.text(l2) == "C 21% · X 91% !", "label: non-auth failure -> ! too")
let l2b = alertLab([ha, hb], [79, 9], [hs(7 * 86400), hs(60)])
check(!l2b.contains(where: \.isAlert), "label: old data but last refresh OK -> no !")
let l3 = alertLab([ha, hb], [nil, nil], [hs(nil, login: true), hs(60)])
check(MenuLabelLogic.text(l3) == "!" && l3.count == 1 && l3[0].level == .red, "label: no data but red -> icon + !")
let l4 = alertLab([ha, hb, hc], [10, 50, 90], [hs(60, login: true), hs(60), hs(60)])
check(l4.count == 3 && l4.filter { !$0.isAlert }.count == 2 && MenuLabelLogic.text(l4).count <= 18, "label: cap keeps 2 percentages + !")

print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

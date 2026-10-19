import AppKit
import WebKit

public enum WebError: Error, LocalizedError {
    case needsLogin, cloudflare, orgMismatch, http(Int), loadFailed, parse
    public var errorDescription: String? {
        switch self {
        case .needsLogin: return "Sign in required"
        case .cloudflare: return "Blocked by Cloudflare challenge"
        case .orgMismatch: return "Web session is a different Claude account"
        case .http(let c): return "HTTP \(c)"
        case .loadFailed: return "Could not load page"
        case .parse: return "Unexpected response"
        }
    }
}

extension AccountKind {
    var web: WebProvider { self == .claude ? .claude : .codex }
}

public enum WebProvider: String {
    case claude, codex
    public var home: URL { URL(string: self == .claude ? "https://claude.ai/" : "https://chatgpt.com/")! }
    public var login: URL { URL(string: self == .claude ? "https://claude.ai/login" : "https://chatgpt.com/auth/login")! }
    public var host: String { self == .claude ? "claude.ai" : "chatgpt.com" }
    public var signInTitle: String { self == .claude ? "Sign in to Claude" : "Sign in to ChatGPT (Codex)" }
    /// Cheap authenticated check run inside the page.
    var authCheckJS: String {
        self == .claude ? """
        try { const r = await fetch('/api/organizations', {credentials: 'include'}); if (!r.ok) return false;
              const j = await r.json(); return Array.isArray(j) && j.length > 0; } catch (e) { return false; }
        """ : """
        try { const r = await fetch('/api/auth/session', {credentials: 'include'}); if (!r.ok) return false;
              const j = await r.json(); return !!(j && typeof j.accessToken === 'string' && j.accessToken.length > 0); } catch (e) { return false; }
        """
    }
}

/// One WKWebView per (data store, provider): hidden offscreen for fetching; visible sign-in window on demand.
@MainActor
public final class WebSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static var sessions: [UUID: WebSession] = [:]
    public static func session(for id: UUID, provider: WebProvider) -> WebSession {
        if let s = sessions[id] { return s }
        let s = WebSession(storeID: id, provider: provider); sessions[id] = s; return s
    }

    public let provider: WebProvider
    let webView: WKWebView
    let window: NSWindow
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var loading = false

    init(storeID: UUID, provider: WebProvider) {
        self.provider = provider
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .transient]
        super.init()
        webView.navigationDelegate = self
        window.orderFrontRegardless()
    }

    private func ensureLoaded() async -> Bool {
        if webView.url?.host?.hasSuffix(provider.host) == true, !webView.isLoading { return true }
        return await withCheckedContinuation { c in
            waiters.append(c)
            if !loading {
                loading = true
                webView.load(URLRequest(url: provider.home))
                DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in self?.finishLoad(false) }
            }
        }
    }
    private func finishLoad(_ ok: Bool) {
        guard loading else { return }
        loading = false
        let w = waiters; waiters = []
        w.forEach { $0.resume(returning: ok) }
    }
    public func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        if w === webView { finishLoad(true) } else { checkSignIn() }
    }
    public func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { if w === webView { finishLoad(false) } }
    public func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { if w === webView { finishLoad(false) } }

    /// Runs `js` (async function body) in the hidden page.
    public func evaluate(_ js: String, args: [String: Any] = [:]) async throws -> Any? {
        guard await ensureLoaded() else { throw WebError.loadFailed }
        do { return try await webView.callAsyncJavaScript(js, arguments: args, in: nil, contentWorld: .page) }
        catch { throw WebError.loadFailed }
    }

    public func isAuthenticated() async -> Bool {
        ((try? await evaluate(provider.authCheckJS)) as? Bool) == true
    }

    // MARK: visible sign-in window; auto-closes once authenticated
    private var signIn: NSWindow?
    private var signInWeb: WKWebView?
    private var children: [NSWindow] = []
    private var onDone: ((Bool) -> Void)?
    private var closeObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var checking = false
    private var finished = false

    public func showSignIn(onDone: @escaping (Bool) -> Void) {
        if let w = signIn { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        Self.installEditMenu()
        self.onDone = onDone; finished = false
        let v = WKWebView(frame: .zero, configuration: webView.configuration)   // same data store + config
        v.uiDelegate = self; v.navigationDelegate = self
        v.load(URLRequest(url: provider.login))
        let w = Self.showWindow(v, width: 520, height: 720)
        w.title = provider.signInTitle
        NSApp.activate(ignoringOtherApps: true)
        signIn = w; signInWeb = v
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.teardown(authenticated: false) }
        }
        let started = Date()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if Date().timeIntervalSince(started) > 600 { self.signIn?.close(); return }   // 10 min timeout
                self.checkSignIn()
            }
        }
    }

    private func checkSignIn() {
        guard let v = signInWeb, !checking, !finished, v.url?.host?.hasSuffix(provider.host) == true else { return }
        checking = true
        v.callAsyncJavaScript(provider.authCheckJS, arguments: [:], in: nil, in: .page) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.checking = false
                if case .success(let any) = r, (any as? Bool) == true { self.teardown(authenticated: true) }
            }
        }
    }

    private func teardown(authenticated: Bool) {
        guard !finished else { return }
        finished = true
        pollTimer?.invalidate(); pollTimer = nil
        if let o = closeObserver { NotificationCenter.default.removeObserver(o); closeObserver = nil }
        children.forEach { $0.close() }; children = []
        let w = signIn; signIn = nil; signInWeb = nil
        w?.close()
        webView.load(URLRequest(url: provider.home))   // hidden page picks up the new session
        let cb = onDone; onDone = nil
        cb?(authenticated)
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.uiDelegate = self
        children.append(Self.showWindow(child, width: 600, height: 700))
        return child
    }

    /// A menu-bar app has no Edit menu, so Cmd+C/V/A would not reach the web view (needed to paste a password).
    private static func installEditMenu() {
        let main = NSApp.mainMenu ?? NSMenu()
        guard !main.items.contains(where: { $0.title == "Edit" }) else { return }
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        main.addItem(item)
        NSApp.mainMenu = main
    }

    private static func showWindow(_ content: NSView, width: CGFloat, height: CGFloat) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.contentView = content
        w.isReleasedWhenClosed = false
        w.center(); w.makeKeyAndOrderFront(nil)
        return w
    }
    public func webViewDidClose(_ webView: WKWebView) { webView.window?.close() }

    public static func removeStore(_ id: UUID) async {
        sessions[id]?.window.close(); sessions[id] = nil
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }
}

// MARK: Claude web (cap + per-model spend)

private let claudeFetchJS = """
async function get(p) {
  try {
    const r = await fetch(p, {credentials: "include", headers: {"accept": "application/json"}});
    const t = await r.text();
    return {status: r.status, cf: /Just a moment/i.test(t) || r.headers.get("cf-mitigated") === "challenge", body: t};
  } catch (e) { return {status: 0, cf: false, body: ""}; }
}
const o = await get("/api/organizations");
const res = {orgsStatus: o.status, orgsCf: o.cf, probes: []};
if (o.status !== 200) return JSON.stringify(res);
let list = [];
try { list = JSON.parse(o.body).map(x => x && x.uuid).filter(Boolean); } catch (e) {}
if (known && list.includes(known)) list = [known];
for (const id of list) {
  const u = await get("/api/organizations/" + id + "/usage");
  res.probes.push({id: id, status: u.status, cf: u.cf, body: u.status === 200 ? u.body : ""});
  let j = null; try { j = JSON.parse(u.body); } catch (e) {}
  if (u.status === 200 && j && j.spend) break;   // a spend block always wins; otherwise keep looking
}
return JSON.stringify(res);
"""

private let claudeSpendJS = """
try {
  const r = await fetch("/api/organizations/" + org + "/usage/spend?start_date=" + start + "&end_date=" + end + "&group_by=model_tier&granularity=daily",
                        {credentials: "include", headers: {"accept": "application/json"}});
  const t = await r.text();
  return JSON.stringify({status: r.status, cf: /Just a moment/i.test(t) || r.headers.get("cf-mitigated") === "challenge", body: r.status === 200 ? t : ""});
} catch (e) { return JSON.stringify({status: 0, cf: false, body: ""}); }
"""

public struct ClaudeWebResult {
    public var cap: CapSnapshot?
    public var models: ModelBreakdown?
    public var org: String?
    public var modelsNote: String?
    public var modelsUnavailable = false   // plan has no per-model spend (404/400/403 or empty series): not an error
    public var spendStatus = 0
}

extension WebSession {
    /// Cap (`/usage`, same shape as the OAuth endpoint) and per-model spend, both from the claude.ai session.
    /// `skipSpend`: this account already showed per-model spend is unavailable; do not call it again.
    public func fetchClaude(knownOrg: String?, skipSpend: Bool = false, now: Date = Date()) async throws -> ClaudeWebResult {
        let start = min(DateUtil.firstOfMonth(now), DateUtil.addDays(now, -6))
        guard let s = try await evaluate(claudeFetchJS, args: ["known": knownOrg ?? ""]) as? String, let d = s.data(using: .utf8),
              let o = jsonAny(d) as? [String: Any] else { throw WebError.parse }
        let os = Int(o.num("orgsStatus") ?? 0)
        if o["orgsCf"] as? Bool == true { throw WebError.cloudflare }
        if os == 401 || os == 403 { throw WebError.needsLogin }
        if os != 200 { throw WebError.http(os) }
        let probes: [OrgUsageProbe] = (o.arr("probes") ?? []).compactMap {
            guard let p = $0 as? [String: Any], let id = p.str("id") else { return nil }
            return OrgUsageProbe(id: id, status: Int(p.num("status") ?? 0), body: p.str("body") ?? "")
        }
        if (o.arr("probes") ?? []).contains(where: { ($0 as? [String: Any])?["cf"] as? Bool == true }) { throw WebError.cloudflare }
        guard let pick = ClaudeOrgPicker.pick(probes) else {
            if !probes.isEmpty, probes.allSatisfy({ $0.status == 401 || $0.status == 403 }) { throw WebError.needsLogin }
            throw WebError.orgMismatch
        }
        var r = ClaudeWebResult(cap: ClaudeParser.parseUsage(Data(pick.body.utf8), now: now), models: nil, org: pick.id, modelsNote: nil)
        guard r.cap != nil else { throw WebError.parse }
        if skipSpend { r.modelsUnavailable = true; return r }
        let sargs: [String: Any] = ["org": pick.id, "start": DateUtil.day(start), "end": DateUtil.day(now)]
        guard let ss = try await evaluate(claudeSpendJS, args: sargs) as? String, let sd = ss.data(using: .utf8),
              let so = jsonAny(sd) as? [String: Any] else { throw WebError.parse }
        if so["cf"] as? Bool == true { throw WebError.cloudflare }
        let st = Int(so.num("status") ?? 0)
        r.spendStatus = st
        if st == 200, let body = so.str("body") {
            if let series = (jsonAny(Data(body.utf8)) as? [String: Any])?.arr("series"), series.isEmpty { r.modelsUnavailable = true }
            else { r.models = ClaudeParser.parseSpend(Data(body.utf8), now: now) }
        }
        if st == 400 || st == 403 || st == 404 { r.modelsUnavailable = true }
        if r.models == nil && !r.modelsUnavailable { r.modelsNote = st == 401 ? "Sign in required" : "HTTP \(st)" }
        return r
    }
}

// MARK: Codex web (chatgpt.com session token, used only inside the page)

private let codexFetchJS = """
function claim(tok) {
  try { const p = JSON.parse(atob(tok.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
        const a = p['https://api.openai.com/auth']; return a && a.chatgpt_account_id || null; } catch (e) { return null; }
}
async function get(p, h) {
  try { const r = await fetch(p, {credentials: 'include', headers: h});
        const t = await r.text(); return {status: r.status, cf: /Just a moment/i.test(t), body: r.status === 200 ? t : ''}; }
  catch (e) { return {status: 0, cf: false, body: ''}; }
}
const s = await get('/api/auth/session', {accept: 'application/json'});
let tok = null;
try { tok = JSON.parse(s.body).accessToken || null; } catch (e) {}
const res = {sessionStatus: s.status, cf: s.cf, hasToken: !!tok};
if (tok) {
  const acct = claim(tok);
  const h = {Authorization: 'Bearer ' + tok, accept: 'application/json'};
  if (acct) h['ChatGPT-Account-Id'] = acct;
  res.accountId = acct;
  const u = await get('/backend-api/wham/usage', h);
  res.usageStatus = u.status; res.usageBody = u.body;
  const d = await get('/backend-api/wham/usage/daily-token-usage-breakdown', h);
  res.dailyStatus = d.status; res.dailyBody = d.body;
}
return JSON.stringify(res);
"""

public struct CodexWebResult {
    public var cap: CapSnapshot?
    public var models: ModelBreakdown?
    public var accountID: String?
    public var capStatus: Int
    public var dailyStatus: Int
}

extension WebSession {
    public func fetchCodex(now: Date = Date()) async throws -> CodexWebResult {
        guard let s = try await evaluate(codexFetchJS) as? String, let d = s.data(using: .utf8),
              let o = jsonAny(d) as? [String: Any] else { throw WebError.parse }
        if o["cf"] as? Bool == true { throw WebError.cloudflare }
        let ss = Int(o.num("sessionStatus") ?? 0)
        if o["hasToken"] as? Bool != true { if ss == 200 || ss == 401 || ss == 403 { throw WebError.needsLogin }; throw WebError.http(ss) }
        let us = Int(o.num("usageStatus") ?? 0), ds = Int(o.num("dailyStatus") ?? 0)
        if us == 401 || us == 403 { throw WebError.needsLogin }
        var r = CodexWebResult(cap: nil, models: nil, accountID: o.str("accountId"), capStatus: us, dailyStatus: ds)
        if us == 200, let b = o.str("usageBody") { r.cap = CodexParser.parseUsage(Data(b.utf8), now: now) }
        if ds == 200, let b = o.str("dailyBody") { r.models = CodexParser.parseDaily(Data(b.utf8), now: now) }
        return r
    }
}

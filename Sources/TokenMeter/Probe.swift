import AppKit
import UsageCore

/// Feasibility probes: print status + redacted shapes only (numbers ok, strings <str>).
enum Probe {
    static let shapeJS = """
    function shape(v, d) {
      if (d > 6) return "<deep>";
      if (v === null) return null;
      if (Array.isArray(v)) { const o = {_len: v.length}; v.slice(0, 1).forEach((x, i) => { o["_item"] = shape(x, d + 1); }); return o; }
      if (typeof v === "object") { const o = {}; for (const k of Object.keys(v)) o[k] = shape(v[k], d + 1); return o; }
      if (typeof v === "string") return "<str>";
      return v;
    }
    async function call(p, h) {
      try {
        const r = await fetch(p, {credentials: "include", headers: h || {accept: "application/json"}});
        const t = await r.text();
        const out = {path: p.replace(/[0-9a-f]{8}-[0-9a-f-]{27}/g, "<org>"), status: r.status, cf: /Just a moment/i.test(t), len: t.length};
        try { out.shape = JSON.stringify(shape(JSON.parse(t), 0)).slice(0, Number(window.__shapeLen || 900)); } catch (e) { out.nonJSON = true; }
        return out;
      } catch (e) { return {path: p, error: "fetch failed"}; }
    }
    """

    static let claudeJS = shapeJS + """
    const orgs = await fetch('/api/organizations', {credentials: 'include'}).then(r => r.json()).catch(() => null);
    if (!Array.isArray(orgs) || !orgs.length) return JSON.stringify([{error: 'not signed in / no orgs'}]);
    window.__shapeLen = 4000;
    const base = '/api/organizations/' + org;
    const res = [];
    for (const p of [base + '/overage_spend_limit', base + '/usage']) res.push(await call(p));
    return JSON.stringify(res);
    """

    static let codexJS = shapeJS + """
    const sres = await fetch('/api/auth/session', {credentials: 'include'});
    let sj = null; try { sj = await sres.json(); } catch (e) {}
    const tok = sj && typeof sj.accessToken === 'string' ? sj.accessToken : null;
    const out = {sessionStatus: sres.status, hasAccessToken: !!tok, tokenLen: tok ? tok.length : 0,
                 sessionKeys: sj && typeof sj === 'object' ? Object.keys(sj) : null, calls: []};
    if (tok) {
      let acct = null;
      try { const p = JSON.parse(atob(tok.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))); const a = p['https://api.openai.com/auth']; acct = a && a.chatgpt_account_id || null; } catch (e) {}
      out.acctClaimPresent = !!acct;
      const h = {Authorization: 'Bearer ' + tok, accept: 'application/json'};
      if (acct) h['ChatGPT-Account-Id'] = acct;
      out.calls.push(await call('/backend-api/wham/usage', h));
      out.calls.push(await call('/backend-api/wham/usage/daily-token-usage-breakdown', h));
    }
    return JSON.stringify(out);
    """

    static func run(_ args: [String]) {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                if args.contains("--probe-claude-web") {
                    let sess = WebSession.session(for: UUID(uuidString: AppPaths.spikeStoreID)!, provider: .claude)
                    // org id (not a secret) from the cache, to scope the probe
                    let cached = (try? Data(contentsOf: AppPaths.cacheFile)).flatMap { jsonAny($0) as? [String: Any] } ?? [:]
                    let cacheOrg = cached.values.compactMap { ($0 as? [String: Any])?["orgUUID"] as? String }.first
                    let r = try await sess.evaluate(claudeJS, args: ["org": cacheOrg ?? ""]) as? String ?? "?"
                    print(pretty(r))
                } else {
                    let storeArg = args.firstIndex(of: "--store").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                    let sess = WebSession.session(for: UUID(uuidString: storeArg ?? AppPaths.codexProbeStoreID)!, provider: .codex)
                    if !(await sess.isAuthenticated()) {
                        guard args.contains("--signin") else { print("codex web: NOT signed in (re-run with --signin to open the sign-in window)"); exit(0) }
                        await withCheckedContinuation { c in sess.showSignIn { ok in print("sign-in finished, authenticated=\(ok)"); c.resume() } }
                    }
                    let r = try await sess.evaluate(codexJS) as? String ?? "?"
                    print(pretty(r))
                }
            } catch { print("probe error: \(error.localizedDescription)") }
            fflush(stdout); exit(0)
        }
        NSApplication.shared.run()
    }

    static func pretty(_ s: String) -> String {
        guard let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d),
              let p = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return s }
        return String(data: p, encoding: .utf8) ?? s
    }
}

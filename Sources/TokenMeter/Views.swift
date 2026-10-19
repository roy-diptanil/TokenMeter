import SwiftUI
import AppKit
import ServiceManagement
import UsageCore

func healthColor(_ h: HealthStatus) -> Color { h == .red ? .red : .green }

/// Small status dot; re-evaluated every 30s so "stale" shows up without a refresh.
struct HealthDot: View {
    @ObservedObject var store: Store
    let account: Account
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            Circle().fill(healthColor(store.health(account))).frame(width: 8, height: 8)
                .help(AccountHealth.detail(account, store.snapshots[account.id], now: ctx.date))
        }
    }
}

/// Quiet summary above the cards; only shown when an account's last refresh failed.
struct HealthSummaryRow: View {
    @ObservedObject var store: Store
    var body: some View {
        let sum = AccountHealth.summary(accounts: store.accounts, snapshots: store.snapshots)
        if let t = sum.target {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(sum.text).foregroundStyle(.red)
                Spacer()
                Button(t.signIn ? "Sign in…" : "Retry") { store.fixFirstAttention() }.controlSize(.small)
            }.font(.caption)
        }
    }
}

func capColor(_ p: Double) -> Color { p >= 90 ? .red : (p >= 75 ? .orange : .green) }

struct CapBar: View {
    var percent: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(capColor(percent)).frame(width: max(4, g.size.width * min(max(percent, 0), 100) / 100))
            }
        }.frame(height: 8)
    }
}

struct MenuLabel: View {
    @ObservedObject var store: Store
    var body: some View {
        let segs = MenuLabelLogic.buildWithAlert(accounts: store.accounts, snapshots: store.snapshots, selectedIDs: store.menuBarAccountIDs)
        Image(nsImage: MenuBarImage.image(segs))
    }
}

/// Single source of truth for per-account actions (⋯ menu and right-click menu).
struct CardActions: View {
    @ObservedObject var store: Store
    let account: Account
    var rename: () -> Void
    var body: some View {
        Button("Sign in…") { store.signIn(account) }
        Button("Rename…") { rename() }
        let canToggle = store.canAddToMenuBar(account)
        Toggle(canToggle ? "Show in menu bar" : "Show in menu bar (3 max — untick another first)",
               isOn: Binding(get: { store.isInMenuBar(account) }, set: { store.setInMenuBar($0, for: account) }))
            .disabled(!canToggle)
            .help(canToggle ? "Pick up to 3 accounts for the menu-bar label" : "3 accounts are already shown; untick another first")
        Divider()
        Button("Remove…", role: .destructive) { store.confirmingRemoval = account.id }
    }
}

struct AccountCard: View {
    @ObservedObject var store: Store
    let account: Account

    /// Never signed in, or the session expired before any data was fetched: show one compact row.
    var signedOut: Bool { snap.webLoginNeeded && snap.cap == nil && snap.models == nil }

    var snap: AccountSnapshot { store.snapshots[account.id] ?? AccountSnapshot() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HealthDot(store: store, account: account)
                Text(account.label).font(.headline)
                Text(account.kind.vendor + (snap.cap?.plan.map { " · \($0)" } ?? "") + (snap.idHint.map { " · …\($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu { CardActions(store: store, account: account, rename: promptRename) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if store.confirmingRemoval == account.id {
                HStack {
                    Text("Remove \(account.label)?").font(.caption.bold())
                    Spacer()
                    Button("Remove") { store.remove(account) }.controlSize(.small)
                    Button("Cancel") { store.confirmingRemoval = nil }.controlSize(.small)
                }
            }
            if let d = store.duplicateOf(account) {
                Text("same account as \(d.label)").font(.caption2).foregroundStyle(.orange)
            }
            if signedOut {
                HStack {
                    Text("Sign in required").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sign in") { store.signIn(account) }.controlSize(.small)
                }
            } else if AccountHealth.status(account, snap) == .red {
                // Stale login: dimmed last-known cap, one message, one button (picker/model rows are stale noise).
                Group {
                    if snap.cap != nil { capSection }
                    barRows
                }.opacity(0.6)
                let f = AccountHealth.failure(account, snap) ?? .signInRequired
                HStack {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text(AccountHealth.reasonLine(f, lastSync: AccountHealth.lastSync(snap), now: ctx.date))
                            .font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    if f.isAuth { Button("Sign in") { store.signIn(account) }.buttonStyle(.borderedProminent).controlSize(.small) }
                    else { Button("Retry") { Task { await store.refresh(account) } }.buttonStyle(.borderedProminent).controlSize(.small) }
                }
            } else {
                capSection
                barRows
                modelSection
                staleness
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        .contextMenu { CardActions(store: store, account: account, rename: promptRename) }
    }

    @ViewBuilder var barRows: some View {
        VStack(spacing: 6) {
                ForEach(snap.cap?.bars ?? [], id: \.name) { b in
                    HStack(spacing: 6) {
                        Text(b.name).font(.caption).frame(width: 70, alignment: .leading)
                        CapBar(percent: b.percent)
                        Text(formatPercent(b.percent)).font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                    .help(b.resetsAt.map { "resets in " + formatCountdown(to: $0) } ?? "")
                }
        }
    }

    @ViewBuilder var capSection: some View {
        if let c = snap.cap, let p = c.percent {
            CapBar(percent: p)
            HStack {
                if account.kind == .claude, let u = c.used, let l = c.limit {
                    Text("\(formatMoney(u)) of \(formatMoney(l)) · \(formatPercent(p))").monospacedDigit()
                } else if c.used == nil, c.limit == nil, let w = c.windowLabel {
                    Text("\(formatPercent(p)) of \(w) limit").monospacedDigit()
                } else {
                    Text("\(formatPercent(p)) of monthly credit cap").monospacedDigit()
                }
                Spacer()
                if let r = c.resetAt {
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text("resets in \(formatCountdown(to: r))").foregroundStyle(.secondary)
                    }
                }
            }.font(.caption)
        } else if snap.cap != nil {
            Text("No monthly cap data").font(.caption).foregroundStyle(.secondary)
        } else {
            HStack {
                Text(snap.capError ?? "Loading…").font(.caption).foregroundStyle(.secondary)
                signInButton
            }
        }
    }

    @ViewBuilder var signInButton: some View {
        if snap.webLoginNeeded { Spacer(); Button("Sign in") { store.signIn(account) }.controlSize(.small) }
    }

    @ViewBuilder var modelSection: some View {
        if snap.models == nil, snap.modelsUnavailable == true, snap.modelsError == nil {
            Text("Per-model breakdown not available for this plan").font(.caption).foregroundStyle(.secondary)
        } else {
        Picker("", selection: Binding(get: { store.window(for: account) }, set: { store.setWindow($0, for: account) })) {
            ForEach(UsageWindow.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden()
        if let m = snap.models {
            let rows = m.rows(store.window(for: account))
            if rows.isEmpty {
                Text("No usage in this window").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(rows, id: \.name) { r in
                        HStack {
                            Text(r.name).lineLimit(1)
                            Spacer()
                            Text(m.unit == "usd" ? formatMoney(r.amount) : String(format: "%.1f", r.amount)).monospacedDigit()
                            Text(formatPercent(r.share)).monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                        }.font(.caption)
                    }
                    if m.unit != "usd" {
                        Text("usage units (relative; not % of cap)").font(.system(size: 9)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        } else {
            HStack {
                Text(snap.modelsError ?? "Per-model: unavailable").font(.caption).foregroundStyle(.secondary)
                signInButton
            }
        }
        if snap.models != nil, let e = snap.modelsError {
            HStack {
                Text("per-model: \(e)").font(.caption2).foregroundStyle(.orange)
                signInButton
            }
        }
        }
    }

    var staleness: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            if let e = snap.capError {
                Text(snap.capUpdated.map { "\(e) · last good \(formatAgo($0))" } ?? e)
                    .font(.caption2).foregroundStyle(.orange)
            } else if let u = snap.capUpdated {
                Text("updated \(formatAgo(u))").font(.caption2)
                    .foregroundStyle(Date().timeIntervalSince(u) > 900 ? Color.orange : Color.secondary)
            }
        }
    }

    func promptRename() {
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24)); f.stringValue = account.label
        let al = NSAlert(); al.messageText = "Rename account"; al.accessoryView = f
        al.addButton(withTitle: "Rename"); al.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if al.runModal() == .alertFirstButtonReturn {
            let name = f.stringValue.trimmingCharacters(in: .whitespaces)
            if !store.rename(account, to: name) { Self.notice("That label is empty or already used by another \(account.kind.title) account.") }
        }
    }

    static func notice(_ m: String) {
        let al = NSAlert(); al.messageText = m; al.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true); al.runModal()
    }
}

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PopoverView: View {
    @ObservedObject var store: Store
    @ObservedObject var updater: UpdateModel
    @State private var contentHeight: CGFloat = 300
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HealthSummaryRow(store: store)
            ScrollView {
                VStack(spacing: 10) {
                    if store.accounts.isEmpty { Text("Add a Claude or Codex account to get started.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 20) }
                    ForEach(store.accounts) { AccountCard(store: store, account: $0) }
                }
                .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            }
            .frame(height: min(max(contentHeight, 120), 560))
            .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
            Divider()
            HStack {
                Button(store.refreshing ? "Refreshing…" : "Refresh now") { Task { await store.refreshAll(announce: true) } }
                    .disabled(store.refreshing)
                Button("Add account…") { promptAdd() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            if let m = store.refreshResult { Text(m).font(.caption).foregroundStyle(.secondary) }
            updateRow
            HStack {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox).font(.caption)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Spacer()
                Text("Version \(updater.installed.short)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12).frame(width: 360)
        .onAppear { store.refreshIfStale(); updater.autoCheck() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in store.refreshIfStale() }
    }

    @ViewBuilder var updateRow: some View {
        let inst = updater.installed
        switch updater.state {
        case .updating:
            Text("Updating… TokenMeter will restart in a minute or two (log: \(UpdateInstaller.logDisplayPath))")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .stalled:
            HStack {
                Text("Update did not finish — see the log").font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Open log") { NSWorkspace.shared.open(UpdateInstaller.logURL) }.controlSize(.small)
            }
        case .result(.updateAvailable):
            HStack {
                Text("Update available").font(.caption.bold())
                Spacer()
                Button("Update now") { updater.startUpdate() }.controlSize(.small)
            }
        default:
            HStack(spacing: 6) {
                Button("Check for updates") { updater.checkNow() }.disabled(updater.busy)
                if updater.state == .checking { ProgressView().controlSize(.small) }
                if case .result(let r) = updater.state {
                    switch r {
                    case .upToDate: Text("Up to date (\(inst.short))").font(.caption).foregroundStyle(.secondary)
                    case .devBuild: Text("Dev build (\(inst.short)\(inst.dirty ? "+local changes" : ""))").font(.caption).foregroundStyle(.secondary)
                    case .checkFailed(let m): Text("Couldn't check: \(m)").font(.caption).foregroundStyle(.orange).lineLimit(2)
                    case .updateAvailable: EmptyView()
                    }
                }
            }
        }
    }

    func promptAdd() {
        let kind = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 220, height: 26))
        kind.addItems(withTitles: AccountKind.allCases.map(\.title))
        let label = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24)); label.placeholderString = "Label"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 60)); box.addSubview(kind); box.addSubview(label)
        let al = NSAlert(); al.messageText = "Add account"
        al.informativeText = "Opens a web sign-in window (claude.ai or chatgpt.com); it closes itself once you are signed in."
        al.accessoryView = box
        al.addButton(withTitle: "Add"); al.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if al.runModal() == .alertFirstButtonReturn {
            if let err = store.add(kind: AccountKind.allCases[kind.indexOfSelectedItem], label: label.stringValue) { AccountCard.notice(err) }
        }
    }
}

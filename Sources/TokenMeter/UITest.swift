import AppKit
import SwiftUI
import UsageCore

enum UITest {
    static func run() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            let a1 = Account(kind: .claude, label: "Claude"), a2 = Account(kind: .codex, label: "Codex")
            var s1 = AccountSnapshot(); var c1 = CapSnapshot(); c1.plan = "Max"; c1.used = 1234.56; c1.limit = 2000; c1.percent = 61.7
            c1.unit = "usd"; c1.resetAt = Date().addingTimeInterval(12 * 86400); c1.bars = [UsageBar(name: "Extra usage", percent: 40)]
            s1.cap = c1; s1.capUpdated = Date()
            var m1 = ModelBreakdown(); m1.d7 = [ModelRow(name: "Claude Opus 5.5", amount: 120, share: 80), ModelRow(name: "Claude Sonnet 5", amount: 30, share: 20)]
            s1.models = m1; s1.idHint = "ab12"
            var s2 = AccountSnapshot(); var c2 = CapSnapshot(); c2.plan = "Business"; c2.percent = 9; c2.unit = "credit"; c2.resetAt = Date().addingTimeInterval(86400)
            s2.cap = c2; s2.capUpdated = Date().addingTimeInterval(-120)
            var m2 = ModelBreakdown(); m2.unit = "units"; m2.d7 = [ModelRow(name: "gpt-x", amount: 10, share: 100)]; s2.models = m2
            // red: session expired (kept last good data)
            let a3 = Account(kind: .claude, label: "Work", webStoreID: UUID().uuidString)
            var s3 = AccountSnapshot(); var c3 = CapSnapshot(); c3.plan = "Pro"; c3.percent = 33; c3.windowLabel = "weekly"; c3.resetAt = Date().addingTimeInterval(3 * 86400)
            s3.cap = c3; s3.capUpdated = Date().addingTimeInterval(-3 * 3600); s3.webLoginNeeded = true; s3.capError = "Sign in required"; s3.modelsError = s3.capError
            s3.refreshFailure = "Sign in required"; s3.refreshFailureIsAuth = true
            // red, non-auth: network error (keeps last good data, shows Retry)
            let a4 = Account(kind: .codex, label: "Team", webStoreID: UUID().uuidString)
            var s4 = AccountSnapshot(); var c4 = CapSnapshot(); c4.plan = "Plus"; c4.percent = 55; c4.windowLabel = "weekly"; c4.resetAt = Date().addingTimeInterval(2 * 86400)
            s4.cap = c4; s4.capUpdated = Date().addingTimeInterval(-3 * 3600); s4.capError = "unavailable: Network error"; s4.modelsError = s4.capError
            s4.refreshFailure = "Network error"; s4.refreshFailureIsAuth = false
            let store = Store(accounts: [a1, a2, a3, a4], snapshots: [a1.id: s1, a2.id: s2, a3.id: s3, a4.id: s4])
            store.setWindow(.d7, for: a1); store.setWindow(.d1, for: a2)   // independent per-account selections
            store.refreshResult = "2 of 4 need attention"
            let updater = UpdateModel(installed: InstalledBuild(commit: String(repeating: "a", count: 40), dirty: false),
                                      state: .result(.updateAvailable(String(repeating: "b", count: 40))))
            store.confirmingRemoval = a2.id
            let card = HStack(alignment: .top, spacing: 12) {
                AccountCard(store: store, account: a2).frame(width: 340)
                VStack(alignment: .leading, spacing: 6) { Text("⋯ menu actions").font(.caption.bold()); CardActions(store: store, account: a2, rename: {}) }
                    .padding(8).background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
            }.padding(12).fixedSize()
            if CommandLine.arguments.contains("--card") {
                let h = NSHostingView(rootView: card); h.appearance = NSAppearance(named: .aqua)
                let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
                w.appearance = h.appearance; w.contentView = h; w.orderFrontRegardless()
                try? await Task.sleep(nanoseconds: 500_000_000)
                let sz = h.fittingSize; h.frame = NSRect(origin: .zero, size: sz); h.layoutSubtreeIfNeeded()
                if let rep = h.bitmapImageRepForCachingDisplay(in: h.bounds) {
                    h.cacheDisplay(in: h.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("card-confirm.png"))
                }
                print("card rendered"); exit(0)
            }
            store.confirmingRemoval = nil
            let login = LoginItemController(service: PreviewLoginItem(), storage: DefaultsLoginItemStorageStub(), bundlePath: "/Applications/TokenMeter.app", commit: "x")
            let host = NSHostingView(rootView: PopoverView(store: store, updater: updater, login: login)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.black.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .padding(28)
                .background(Color(white: 0.62)))
            let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 380, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
            host.appearance = NSAppearance(named: .aqua); w.appearance = host.appearance; w.contentView = host; w.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 800_000_000)
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("popover.png"))
            }
            print("fittingSize: \(Int(size.width))x\(Int(size.height))")
            let ok = size.height > 200
            print("png: " + FileManager.default.temporaryDirectory.appendingPathComponent("popover.png").path)
            print(ok ? "UI OK" : "UI FAIL: popover too short")
            exit(ok ? 0 : 1)
        }
        NSApplication.shared.run()
    }
}

private struct PreviewLoginItem: LoginItemService {
    var status: LoginItemStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}
private final class DefaultsLoginItemStorageStub: LoginItemStorage { var intent: Bool?; var path: String?; var commit: String? }

import Foundation
import UsageCore

/// `--login-item status|on|off`: headless diagnostics and cleanup for the login item. No GUI.
enum LoginItemTool {
    static func run(_ args: [String]) -> Never {
        let action = args.firstIndex(of: "--login-item").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
        guard ["status", "on", "off"].contains(action) else {
            print("usage: --login-item status|on|off"); exit(2)
        }
        MainActor.assumeIsolated {
            let c = LoginItemController(service: SystemLoginItemService(), storage: DefaultsLoginItemStorage(),
                                        bundlePath: Bundle.main.bundlePath, commit: InstalledBuild.current.commit ?? "unknown")
            let line: @MainActor () -> String = { c.refresh(); return LoginItemCLI.format(status: c.status, installed: c.installed, path: c.bundlePath) }
            if action == "status" { print(line()); exit(0) }
            if action == "on", !c.installed {
                print("refusing: not running from an installed location (/Applications or ~/Applications)"); print(line()); exit(1)
            }
            c.setEnabled(action == "on")
            print(line())
            if let m = c.message { print("error: \(m)"); exit(1) }
            exit(0)
        }
        exit(0)
    }
}

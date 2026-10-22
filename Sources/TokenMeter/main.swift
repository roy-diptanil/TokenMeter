import AppKit
if let i = CommandLine.arguments.firstIndex(of: "--make-iconset"), i + 1 < CommandLine.arguments.count {
    NSApplication.shared.setActivationPolicy(.accessory)
    GaugeIcon.writeIconset(to: CommandLine.arguments[i + 1]); exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render-label"), i + 1 < CommandLine.arguments.count {
    NSApplication.shared.setActivationPolicy(.accessory)
    LabelPreview.render(to: CommandLine.arguments[i + 1]); exit(0)
}
import Foundation
if CommandLine.arguments.contains("--login-item") { LoginItemTool.run(CommandLine.arguments) }
if CommandLine.arguments.contains("--probe-claude-web") || CommandLine.arguments.contains("--probe-codex-web") { Probe.run(CommandLine.arguments) } else if CommandLine.arguments.contains("--selftest-ui") { UITest.run() } else if CommandLine.arguments.contains("--dump") { Dump.run() } else { UsageApp.main() }

import Foundation
import ServiceManagement

public enum LoginItemStatus: String, Equatable {
    case notRegistered, enabled, requiresApproval, notFound, unknown
}

public protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// The real thing: SMAppService.mainApp.
public struct SystemLoginItemService: LoginItemService {
    public init() {}
    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// What the user wanted and which copy last registered the login item.
public protocol LoginItemStorage: AnyObject {
    var intent: Bool? { get set }
    var path: String? { get set }
    var commit: String? { get set }
}

public final class DefaultsLoginItemStorage: LoginItemStorage {
    public init() {}
    private let d = UserDefaults.standard
    public var intent: Bool? {
        get { d.object(forKey: "tokenmeter.launchAtLogin") as? Bool }
        set { if let v = newValue { d.set(v, forKey: "tokenmeter.launchAtLogin") } else { d.removeObject(forKey: "tokenmeter.launchAtLogin") } }
    }
    public var path: String? {
        get { d.string(forKey: "tokenmeter.launchAtLogin.path") }
        set { d.set(newValue, forKey: "tokenmeter.launchAtLogin.path") }
    }
    public var commit: String? {
        get { d.string(forKey: "tokenmeter.launchAtLogin.commit") }
        set { d.set(newValue, forKey: "tokenmeter.launchAtLogin.commit") }
    }
}

@MainActor
public final class LoginItemController: ObservableObject {
    @Published public private(set) var status: LoginItemStatus
    @Published public private(set) var message: String?     // last register/unregister error, until the next success
    private let service: LoginItemService
    private let storage: LoginItemStorage
    public let bundlePath: String
    public let commit: String
    public let installed: Bool

    /// Installed location = under /Applications or ~/Applications, and not inside any folder named "build".
    public nonisolated static func isInstalledLocation(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        let h = URL(fileURLWithPath: home).standardizedFileURL.path
        guard p.hasPrefix("/Applications/") || p.hasPrefix(h + "/Applications/") else { return false }
        return !p.split(separator: "/").contains("build")
    }

    public init(service: LoginItemService, storage: LoginItemStorage, bundlePath: String, commit: String, home: String = NSHomeDirectory()) {
        self.service = service; self.storage = storage; self.bundlePath = bundlePath; self.commit = commit
        self.installed = Self.isInstalledLocation(bundlePath, home: home)
        self.status = service.status
    }

    /// The running app, with self-healing scheduled at launch.
    public static func live() -> LoginItemController {
        let c = LoginItemController(service: SystemLoginItemService(), storage: DefaultsLoginItemStorage(),
                                    bundlePath: Bundle.main.bundlePath, commit: InstalledBuild.current.commit ?? "unknown")
        DispatchQueue.main.async { c.selfHeal() }
        return c
    }

    public var canToggle: Bool { installed }
    public var isOn: Bool { status == .enabled }
    public var needsApproval: Bool { status == .requiresApproval }

    /// Re-read from the system (call whenever the popover appears).
    public func refresh() { status = service.status }

    public func setEnabled(_ on: Bool) {
        guard installed else { refresh(); return }   // never registers a build-folder copy
        do {
            if on { try service.register() } else { try service.unregister() }
            storage.intent = on
            if on { storage.path = bundlePath; storage.commit = commit }
            message = nil
        } catch {
            message = error.localizedDescription
        }
        refresh()
    }

    /// At launch from an installed location: if the user wants it on but the registration is missing or belongs to another
    /// path/commit (update, reinstall, re-sign), re-register it. Does nothing when the intent is off.
    public func selfHeal() {
        guard installed else { return }
        refresh()
        guard let intent = storage.intent else {
            if status == .enabled { storage.intent = true; storage.path = bundlePath; storage.commit = commit }
            return
        }
        guard intent else { return }
        guard status != .enabled || storage.path != bundlePath || storage.commit != commit else { return }
        try? service.unregister()
        do {
            try service.register()
            storage.path = bundlePath; storage.commit = commit
            message = nil
        } catch {
            message = "Launch at login: " + error.localizedDescription
        }
        refresh()
    }

    public func openSettings() { service.openSystemSettings() }
}

public enum LoginItemCLI {
    /// `status=<enum> installedLocation=<true|false> path=<path with $HOME as ~>`
    public static func format(status: LoginItemStatus, installed: Bool, path: String, home: String = NSHomeDirectory()) -> String {
        let p = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        return "status=\(status.rawValue) installedLocation=\(installed) path=\(p)"
    }
}

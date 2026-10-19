import Foundation

public enum AppPaths {
    public static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TokenMeter")
    }
    public static var registryFile: URL { supportDir.appendingPathComponent("accounts.json") }
    public static var cacheFile: URL { supportDir.appendingPathComponent("cache.json") }
    public static func accountDir(_ id: String) -> URL { supportDir.appendingPathComponent("accounts/\(id)") }
    /// Web data stores used only by the --probe-* debug flags.
    public static let codexProbeStoreID = "C0DE0001-5A1D-4B2E-8F3A-7D6C5B4A3921"
    public static let spikeStoreID = "5B1C2A7E-3D4F-4A6B-9C8D-0E1F2A3B4C5D"
}

public enum Registry {
    /// A missing file means first launch: start with no accounts. An existing (even empty/unreadable) file is respected.
    public static func load(from url: URL = AppPaths.registryFile) -> [Account] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let d = try? Data(contentsOf: url), let a = try? JSONDecoder().decode([Account].self, from: d) else { return [] }
        return a
    }
    public static func save(_ a: [Account], to url: URL = AppPaths.registryFile) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(a) { try? d.write(to: url, options: .atomic) }
    }

    /// New accounts get a fresh web data store.
    public static func makeAccount(kind: AccountKind, label: String) -> Account {
        Account(kind: kind, label: label, webStoreID: UUID().uuidString)
    }

    /// Pure registry removal (used by Store.remove and tests).
    public static func removing(_ id: String, from a: [Account]) -> [Account] { a.filter { $0.id != id } }
}

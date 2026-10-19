import SwiftUI
import AppKit
import UsageCore

struct UsageApp: App {
    @StateObject private var store = Store()
    @StateObject private var updater = UpdateModel()
    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store, updater: updater).task { store.start() }
        } label: {
            MenuLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

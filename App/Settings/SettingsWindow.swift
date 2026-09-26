import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView(model: model)
            }
            Tab("Hot Keys", systemImage: "keyboard") {
                HotkeysSettingsView(model: model)
            }
            Tab("Profiles", systemImage: "person.2") {
                ProfilesSettingsView(model: model)
            }
            Tab("Groups", systemImage: "square.grid.2x2") {
                GroupsSettingsView(model: model)
            }
            Tab("Triggers", systemImage: "bolt") {
                TriggersSettingsView(model: model)
            }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") {
                AdvancedSettingsView(model: model)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
    }
}

/// Hosts `SettingsView` in a plain window, like the Items window. Closing it saves any edit
/// still waiting and leaves the app running.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel

    init(controller: SomabarController) {
        model = SettingsModel(controller: controller)
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.title = "Somabar Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 520))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not used")
    }

    func present() {
        model.documentDidChange()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func documentDidChange() {
        model.documentDidChange()
    }

    override func close() {
        model.saveNow()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        model.saveNow()
    }
}

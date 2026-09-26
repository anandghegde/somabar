import AppKit
import BarEngine
import os
import SomabarCore

/// The glyph's click handling and its menu.
extension SomabarController {
    // MARK: - Glyph and menu

    func configureControlButton() {
        guard let button = engine.controlButton else { return }
        button.target = self
        button.action = #selector(controlClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func controlClicked(_ sender: NSStatusBarButton) {
        guard !ItemMover.isMoving else { return }
        log.notice("Glyph clicked: \(NSApp.currentEvent.map { String(describing: $0.type) } ?? "no event", privacy: .public)")
        guard let event = NSApp.currentEvent else {
            toggleHidden()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        } else if event.modifierFlags.contains(.option) {
            toggleTucked()
        } else {
            toggleHidden()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggle = menu.addItem(withTitle: engine.isHiddenRevealed ? "Hide Items" : "Reveal Hidden Items",
                                  action: #selector(toggleHiddenAction), keyEquivalent: "")
        apply(document.combo(for: .toggleHidden), to: toggle)
        menu.addItem(withTitle: engine.isTuckedRevealed ? "Hide Tucked Items" : "Reveal Tucked Items Too",
                     action: #selector(toggleTuckedAction), keyEquivalent: "")
        menu.addItem(.separator())

        let searchItem = menu.addItem(withTitle: "Search Items…", action: #selector(searchItemsAction), keyEquivalent: "")
        apply(document.combo(for: .searchItems), to: searchItem)
        let trayItem = menu.addItem(withTitle: "Hidden Items Tray…", action: #selector(openTrayAction), keyEquivalent: "")
        apply(document.combo(for: .openTray), to: trayItem)
        menu.addItem(withTitle: "Items…", action: #selector(showItemsAction), keyEquivalent: "")

        let profiles = NSMenu()
        for profile in document.profiles {
            let item = profiles.addItem(withTitle: profile.name, action: #selector(switchProfileAction(_:)), keyEquivalent: "")
            item.state = profile.name == document.activeProfile ? .on : .off
            item.representedObject = profile.name
            item.target = self
        }
        if !canMoveItems {
            profiles.addItem(.separator())
            let note = profiles.addItem(withTitle: "Rearranging items needs Accessibility access", action: nil, keyEquivalent: "")
            note.isEnabled = false
        }
        let profileItem = menu.addItem(withTitle: "Profile", action: nil, keyEquivalent: "")
        apply(document.combo(for: .cycleProfile), to: profileItem)
        profileItem.submenu = profiles
        addTriggersMenu(to: menu)
        menu.addItem(.separator())

        let dividers = menu.addItem(withTitle: "Show Dividers", action: #selector(toggleDividersAction), keyEquivalent: "")
        dividers.state = engine.showsDividers ? .on : .off
        menu.addItem(withTitle: "Rescan Menu Bar", action: #selector(rescanAction), keyEquivalent: "")
        menu.addItem(withTitle: "Reset Somabar's Positions", action: #selector(resetPositionsAction), keyEquivalent: "")
        if !AccessibilityPermission.isTrusted {
            menu.addItem(withTitle: "Grant Accessibility Access…", action: #selector(grantAccessAction), keyEquivalent: "")
        }
        addUpdatesItem(to: menu)
        menu.addItem(withTitle: "Settings…", action: #selector(showSettingsAction), keyEquivalent: ",")
        menu.addItem(.separator())

        let about: String
        switch engine.capability {
        case .full: about = "Somabar \(Self.version) · macOS 26 backend"
        case .glyphOnly: about = "Somabar \(Self.version) · no backend for this macOS"
        }
        menu.addItem(withTitle: about, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Quit Somabar", action: #selector(quitAction), keyEquivalent: "q")

        for item in menu.items where item.action != nil {
            item.target = self
        }
    }

    private func apply(_ combo: KeyCombo?, to item: NSMenuItem) {
        guard let combo else { return }
        item.keyEquivalent = KeyCodes.menuKeyEquivalent(for: combo.key)
        item.keyEquivalentModifierMask = KeyCodes.modifierFlags(combo.modifiers)
    }

    @objc private func toggleHiddenAction() { toggleHidden() }
    @objc private func toggleTuckedAction() { toggleTucked() }
    @objc private func showItemsAction() { showItems() }
    @objc private func rescanAction() { scanNow(reason: "menu") }
    @objc private func quitAction() { NSApp.terminate(nil) }

    @objc private func switchProfileAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        switchProfile(to: name)
    }

    @objc private func toggleDividersAction() {
        engine.showsDividers.toggle()
        document.preferences.showDividers = engine.showsDividers
        saveDocument(reason: engine.showsDividers ? "Showed dividers" : "Hid dividers")
    }

    @objc private func resetPositionsAction() {
        engine.resetPositions()
        scheduleScan(after: 1.0, reason: "reset positions")
    }

    @objc private func grantAccessAction() {
        requestAccessibility()
    }
}

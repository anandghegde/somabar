import AppKit
import BarEngine
import os
import SomabarCore

/// Hide and reveal: the hidden and tucked sections, and the rehide timer.
extension SomabarController {
    var isRevealed: Bool { engine.isHiddenRevealed }

    func reveal(includingTucked: Bool) {
        guard !reconciler.isRunning else { return }
        engine.setHiddenRevealed(true)
        if includingTucked {
            engine.setTuckedRevealed(true)
        }
        clearNewItemsDot()
        menus.start()
        scheduleRehide()
        scheduleScan(after: 0.6, reason: "reveal")
    }

    func hideAll() {
        guard !reconciler.isRunning else { return }
        engine.setTuckedRevealed(false)
        engine.setHiddenRevealed(false)
        rehide.cancel()
        menus.stop()
        scheduleScan(after: 0.6, reason: "hide")
    }

    func toggleHidden() {
        if engine.isHiddenRevealed {
            hideAll()
        } else {
            reveal(includingTucked: false)
        }
    }

    func toggleTucked() {
        if engine.isTuckedRevealed {
            hideAll()
        } else {
            reveal(includingTucked: true)
        }
    }

    func scheduleRehide() {
        let seconds = document.preferences.rehideAfterSeconds
        guard seconds > 0, !document.preferences.stillMode else {
            rehide.cancel()
            return
        }
        rehide.onFire = { [weak self] in self?.hideAll() }
        rehide.schedule(after: seconds)
    }
}

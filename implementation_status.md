# Implementation status

Slice 2, "engine alpha on macOS 26", plus the trigger runtime, plus the Slice 3 surfaces (search
palette, Hidden items tray, Settings with a trigger editor, trigger notifications, the notch
surface and timer, the wide-display rule), which build and are unit-tested but have not been
opened by hand. Last updated 2026-09-26 on macOS 26.4.1, Xcode 26.4.1, Swift 6.3.1, a Mac mini
M4 with one 4K display (1920 × 1080 points, no notch), on Ethernet, with a Screen Sharing
session open to it.

Slice 1 ("engine skeleton") findings that still hold are kept below under *Still true from
Slice 1*.

## Verified on this machine

Each line was checked by running the Debug build with Accessibility trust and reading the unified
log, the window server, screenshots of the bar, or the layout file. Input for the checks was
synthetic (`CGEvent` posted to the HID tap from a trusted terminal); a human hand has not yet
driven the gestures.

- **The item mover works.** Switching Everyday → Focus moved five items Shown → Hidden in about
  3 s (⌘-drag through synthetic events, one item at a time, verified against the window list after
  each drag); Focus → Everyday moved them back, and their physical order matched the layout. The
  reconciler logs each move (`Moved <item>: Hidden → Shown`) and a summary
  (`Reconciled the bar (<reason>): moved 5, failed 0, skipped 0`).
- **The layout is the truth (M16).** A scan compares the bar to the active profile. Anything in
  the wrong section is logged as drift (`Drift: <item> Tucked→Shown`) and moved once. Items the
  reconciler cannot act on are left alone: everything is skipped without trust, and Apple's own
  items are never touched.
- **Profiles switch** through the glyph's menu or `somabar://profile?Focus`; the document records
  the active profile and the bar is rearranged on the next scan.
- **New items go where the profile says, with a dot on the glyph (M18).** A never-seen status
  item was noticed within 2 s of appearing, logged as `New items: …`, placed in Shown (Everyday's
  `newItemsGoTo`) by one move, and the glyph showed a dot until the next reveal cleared it (seen in
  a screenshot of the bar). Items are noticed three ways: the app-launch notification, a 3 s poll
  of the status-window list (an app can add its item long after launch, and a launchd agent posts
  no notification), and any other scan.
- **Reveal gestures (M2).** With the defaults, a click on the empty bar reveals and a second click
  hides. With scroll on, three wheel ticks down on the bar reveal and ticks up hide, with a 1 s
  cooldown. With hover on, resting on the empty bar for 300 ms reveals. Two interactions were
  found and fixed: a hover armed under a click no longer fires during the click's menu check
  (which turned a reveal click into a hide), and a bar hidden under a resting pointer stays hidden
  until the pointer leaves the bar and comes back.
- **Menu-aware auto-rehide (M3).** The 8 s timer hides the bar. While a menu hangs from the bar
  the timer waits and looks again every second (`Rehide timer fired under an open menu`); when
  the menu closes the bar hides 0.4 s later. A click on the empty bar while a menu is open closes
  the menu and does nothing else. With the pointer on the bar the timer also waits, looking again
  every 1.5 s.
- **Control Center-hosted agent items are managed by macOS.** Screen Sharing's item belongs to
  `com.apple.SSMenuAgent` but Control Center exposes an untitled element over it and pulls it back
  on screen whenever the divider collapses. Such items are marked hosted, never moved, and shown
  as managed in the Items window; before this the reconciler moved it every reveal.
- **Somabar's own windows are not items.** On macOS 26 Control Center owns the glyph and the
  collapsed dividers too, so the empty-bar hit test filters them out by frame; without that every
  click on the empty bar counted as a click on an item.
- **One copy at a time.** A second launch, from `make run` or the binary, quits at once with
  "Somabar is already running (pid N)" on stderr and in the log. Before this guard two
  overlapping copies each learned the other's glyph and dividers as items and saved them into
  every profile. The scanner now drops any item of Somabar's bundle whichever process owns it
  (unit-tested), and at launch a layout file that already holds such keys is cleaned and saved
  ("Dropped 5 of Somabar's own items", verified live).
- **Triggers run end to end.** Checked on a copy of this layout (`SOMABAR_DOCUMENT_DIR`) with
  three triggers, driven by `open "somabar://set?…"` from a terminal: `external` "docker" hides
  CleanShot X's item, `external` "meeting" switches to Presenting, and `timeOfDay` 19:00–07:00
  switches to a profile that does not exist.
  - The context at launch read `adapter, ethernet, router b0:39:…, 1 display (external), screen
    shared, mic, front com.mitchellh.ghostty, 11:03`. The router's hardware address came from
    the ARP table and matched `arp -n`; screen sharing came from the first scan seeing
    `com.apple.SSMenuAgent`'s item; the front app, the network path and the minute each logged
    `Context changed (<reason>)` as they changed.
  - `docker=on` logged `Triggers holding (set docker=on): Docker from a script` and
    `Triggers apply: show [], hide [pl.maketheweb.cleanshotx]`; the next scan found the item
    `Shown→Hidden` and the reconciler moved it in about a second. `docker=off` moved it back
    the same way. The stored layout kept the item in Shown throughout: the effect lives in
    `effectiveLayout`, not in the file.
  - `meeting=on` logged `Switched to profile Presenting by trigger`, saved with
    `profileBeforeTriggers` set to Everyday, and the next scan moved four items Shown→Tucked in
    3 s. `meeting=off` logged `Trigger ended; back to profile Everyday`, saved with
    `profileBeforeTriggers` cleared, and moved the four back in 7 s (`moved 4, failed 0`).
  - A condition that flips while the reconciler is mid-pass is safe: the pass stops after the
    move it is on (`Layout changed (triggers: …); stopping the reconcile in flight`), the scan
    the change asked for waits (`Scan (…) waits for the reconcile to end`), and a fresh pass
    follows for the new layout.
  - The unknown-profile trigger never held (its window was closed at 11:00), so the
    `A trigger asks for the profile … which the layout file does not have` error is unit-tested
    only.
- **Logging.** Categories `Controller`, `DividerBackend`, `Hotkeys`, `ItemMover`, `Gestures`,
  `Reconciler`, `Rehide`, `Menus`, `Items`, `Triggers`, `Displays`. Read with
  `/usr/bin/log show --last 5m --predicate 'subsystem == "app.somabar"' --info --style compact`.
  Only `.info` and above persist; `.debug` lines do not show up in `log show`.
- 173 unit tests in 36 suites pass (`swift test`); `swiftlint` is clean; the app target builds.

## Unverified or assumed

- **Notch guard runtime (M6).** The layout side runs on every scan (Shown items under the housing
  move to Hidden and are restored when there is room; `notchGuarded` is stored per profile) and is
  unit-tested, but this machine has no notch, so it never fired. `notchGuarded` decodes as empty
  from older files.
- **⌃⌥P and the other hot keys**, and clicks on the glyph, still need a human: synthetic key
  events do not reach Carbon hot keys (Slice 1 finding). Profile switching was driven by URL.
- **A person's ⌘-drag being learned.** The rule (an item that was where the layout said at the
  last scan and is elsewhere now was moved by the person) is unit-tested; nobody has dragged an
  item by hand with Somabar watching.
- **Hover and scroll by a real trackpad or mouse.** Verified with synthetic HID events only, and
  both are off by default; edit `revealGestures` in the layout file to turn them on until
  Settings exists.
- **Clicks on the collapsed divider itself.** macOS caps the divider at 5,016 pt and reports it
  off screen, so it never receives a click; the global monitor handles empty-bar clicks instead.
  The divider's click path stays wired for a macOS that behaves differently.
- **Multiple displays.** Everything assumes the primary display.
- **Rehide when the app changes** was verified in Slice 1 only.
- **Corrupt layout file** is moved aside as `layout.broken-<timestamp>.somabar`; not exercised.
- **Trigger conditions this machine cannot produce.** A Mac mini has no battery, so `powerSource`
  and `batteryBelow` were only checked to read "adapter, no battery" (IOKit power sources); the
  battery branch is unit-tested against a snapshot. There is no camera, so `mediaInUse(camera)`
  reads false through CoreMediaIO and its listener has never fired. Wi-Fi, a VPN tunnel, a
  display being plugged or unplugged, and a Focus change were not exercised; the network path
  monitor, the tunnel heuristic (`utun`/`ipsec`/`ppp`/`tun`/`tap`/`wg` interfaces that are up
  and carry a routable address; macOS's own `utun0`–`utun4` carry only link-local IPv6 and are
  ignored, unit-tested) and the display notification are wired but were only seen at rest.
- **The Focus Filter.** `SomabarFocusFilter` builds into the app's AppIntents metadata, but
  nobody has added it to a Focus in System Settings yet, so `focus` conditions are untested end
  to end. AppIntents may launch Somabar to run the filter when a Focus changes while it is not
  running; that would be harmless (the filter only posts a notification) but is unconfirmed.
- **Screen sharing is read off the bar.** `screenSharing` holds while the scan sees
  `com.apple.SSMenuAgent`'s item, which macOS shows for its own Screen Sharing sessions. Zoom,
  Meet and other apps that capture the screen are not detected; the PRD's "sharing the screen"
  is narrower here than a person might expect.
- **A trigger holding an item the person then ⌘-drags** (the trigger leaves it alone until its
  condition ends) is unit-tested on the runtime; no hand has dragged a held item.
- **Time-of-day triggers** tick once a minute (`Context changed (minute)` was seen) but no
  window edge was crossed during testing.
- **The "Triggers" submenu** (what holds, which profile comes back, "Remember This Router") is
  built but has not been opened; `knownRouter` conditions therefore ran only in unit tests.
- **Search palette and tray** are unit-tested for ranking only (`ItemSearchTests`); neither
  window has been opened by a hand. Unconfirmed: that the non-activating panels take typing and
  ⎋ while another app stays in front, that a click outside or on the bar closes them, where the
  tray lands on a notched or multi-display Mac, and that the hot keys (⌃⌥/, ⌃⌥↓) fire. "Items…"
  no longer shows ⌃⌥/; that shortcut now belongs to "Search Items…".
- **Opening an item from the palette or tray** uses `AXPress` with a 0.5 s timeout and treats a
  timeout as success, because some apps answer only once their menu closes. Without an element
  it clicks the item's window through `ItemMover.click` after waiting up to 1.2 s for the
  revealed item to settle. Neither path has been exercised on a real bar; Apple's, hosted and
  unidentified items only get the pointer.
- **Settings window.** Builds, and its editing rules are unit-tested (hot key clashes, profile
  rename/remove/add, condition editor round trips, the `notifyWhenTriggerFires` default and
  round trip), but nobody has opened it. Unconfirmed on a real Mac: the key recorder taking
  focus in a menu-bar-only app, ⌘-combos reaching it, and hot keys being switched off during
  recording and back on afterwards; whether the live changes (gestures, dividers, the notch
  guard rescan, trigger re-evaluation) take effect without a relaunch; and ⌘, from the glyph's
  menu. Spacing is saved but not yet applied to the bar. Edits are saved 0.8 s after the last
  change, and whatever is still waiting is saved when the window closes.
- **Trigger notifications.** `.somabarTriggerFired` is posted when a trigger starts holding or
  switches profile; when the person asks for it, a system notification follows, but not at
  launch. The permission prompt and delivery have not been seen on an ad-hoc signed build, nor
  whether the banner shows while Settings is in front.
- **The notch surface has not been seen.** It builds, and its timer and the display rule are
  unit-tested, but nobody has watched it. This Mac has no notch, so only the drawn notch
  (`drawnNotch: true`) can be tried here. The camera-housing layout (56 pt of compact beside
  the camera, 80 pt for a pulse, truncated pulse text) and the choice of the built-in display
  when it has a notch are assumed. Hover intent, the click-through of the transparent canvas
  (`ignoresMouseEvents` toggled on pointer moves), and first-click buttons on the
  non-activating panel while another app is active all need a real pointer. The trigger pulse
  listens for `app.somabar.triggerFired` with `userInfo["names"]`. The surface is rebuilt on a
  screen-parameters change only when the notch geometry changed, and a running timer carries
  over; neither has been exercised. The hot key for the 25-minute timer is unassigned by
  default; without a surface (no notch and `drawnNotch` off) it and `somabar://timer` only
  log a notice.
- **Show everything above N points** is applied in `effectiveLayout` (display rule first, then
  triggers, so a trigger's hide still wins) and unit-tested, but this display is 1920 pt wide,
  so it has never held. Dragging an item into Hidden by hand while it holds is learned into the
  file, but the rule then brings the item back into Shown. `leaveInactiveDisplaysUntouched`
  does nothing because Somabar only manages the primary display.

## Deviations from the PRD

- **Discovery needs Accessibility on macOS 26** (Slice 1). Without it the bar is adopted as it
  is: nothing moves, profiles still switch but only the record changes, and new items are not
  moved.
- **Divider length is capped near 5,000 pt** by the system (Slice 1).
- **Rehide when a menu closes only shortens an active auto-rehide.** With `rehideAfterSeconds`
  at 0 or Still Mode on, closing a menu does not hide the bar; the preference never hides a bar
  that auto-rehide leaves alone.
- **Apple's Control Center-hosted agent items cannot be managed** (see above); the PRD's "the
  system's own items are left alone" now covers them.
- **Order within a section is only kept among moved items.** Each ⌘-drag lands next to the
  divider, so the reconciler moves items in the order that leaves the layout's order on the bar;
  items that were already in the right section keep whatever order the bar shows and the layout
  learns it.

## Findings worth knowing

- **Trust is lost on every ad-hoc rebuild.** Launching the binary from a terminal that already
  has Accessibility access inherits that trust:
  `.build/xcode/Build/Products/Debug/Somabar.app/Contents/MacOS/Somabar &` reports
  `trusted: true`; `open` or `make run` does not.
- **Synthetic clicks need `mouseEventClickState = 1`** on the down and up events or AppKit ignores
  them; posting to the HID tap is what reaches a global monitor.
- **New status items appear at the far left of the bar**, i.e. behind the collapsed divider, so
  they start hidden and the reconciler brings them to Shown.
- **Somabar never saves a document that did not change**: 7 saves in 33 scans during testing.
- **A reconcile pass stops when the layout changes under it.** Found by the trigger test: the
  pass that tucked items for Presenting was still dragging when the trigger ended, so it kept
  tucking items in Everyday, and the "moved N s ago and drifted again" guard then refused to
  move them back for 60 s. Now a profile switch or a trigger effect cancels the pass in flight
  (`stopped because the layout changed` in the outcome), a scan asked for during a pass waits for
  it to end, and the guard only fires when an item is asked to go to the *same* section it was
  just moved to.
- **`avconferenced` holds the microphone during a Screen Sharing session**, so `mediaInUse
  (microphone)` holds for as long as someone is connected with audio. CoreAudio's process list
  says so, and macOS shows its orange dot for the same reason.
- **The camera and microphone usage strings** in `Info.plist` are a safety net only: the
  device-in-use properties Somabar reads need no permission, and it never records anything. Should
  macOS ever gate those reads, it will ask instead of ending the process.
- **`SOMABAR_DOCUMENT_DIR`** points a copy of Somabar at another layout directory, which is how
  triggers were tested against a copy of the real file. Only one copy runs at a time either way.

## Not built yet

Updates (Sparkle needs a feed URL and a signing key), display rules beyond the width rule
(`leaveInactiveDisplaysUntouched` is a comment; Somabar manages the primary display only),
`spacing` (saved by Settings, not applied), real item images (`realItemImages` is saved but the
palette and tray always draw app icons), and the `iconChanged` condition in the trigger editor
(the file still accepts it). The timer is the notch's only activity so far; the per-profile
activity toggles Settings shows are saved but nothing else feeds the compact state.

## Built since the last verified run (2026-09-26)

- Search palette: `App/SearchPalette.swift`, ranking in `Sources/SomabarCore/ItemSearch.swift`.
- Hidden items tray: `App/TrayWindow.swift`; `ItemMover.click(_:at:)` is the fallback opener.
- Settings: `App/Settings/`, editing rules in `Sources/SomabarCore/SettingsEditing.swift`;
  `App/Notifications.swift` posts `.somabarTriggerFired` and delivers the system notification.
- Notch surface: `App/Notch/`; `Sources/NotchKit/NotchTimer.swift` is the countdown model (the
  machine's own timer enum was renamed `NotchMachineTimer` to make room);
  `Sources/SomabarCore/DisplayRuleEvaluator.swift` is the width rule. `ContextMonitor` gained an
  `onDisplaysChanged` callback on its existing screen-parameters observer.
- Preferences gained `drawnNotch` and `notifyWhenTriggerFires`, both decoded as false from
  older files.

## Still true from Slice 1

- Three status items (Tucked divider, Hidden divider, glyph) in the right order; collapsing to
  5,016 pt hides everything left of a divider.
- `somabar://reveal`, `somabar://hide`, `somabar://toggle`, `somabar://reveal?tucked`,
  `somabar://items`, `somabar://rescan`, `somabar://profile?Focus` and
  `somabar://set?docker=on` work.
- Every status item window belongs to Control Center; Accessibility identifies the owners (frames
  inset 7–8 pt inside the window); zero-size Control Center frames are ignored.
- The layout file lives at `~/Library/Application Support/Somabar/layout.somabar` with a
  `history/` folder of dated copies.

## How to run

```sh
make test   # SomabarCore, BarEngine, NotchKit unit tests
make lint   # swiftlint
make app    # xcodegen + xcodebuild into .build/xcode
make run    # build and launch
```

The build is ad-hoc signed, so Accessibility trust is tied to the signature and each rebuild needs
the permission again ("Grant Accessibility Access…" in the glyph's menu), or launch the binary
from a trusted terminal as described above.

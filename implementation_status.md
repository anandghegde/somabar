# Implementation status

Slice 2, "engine alpha on macOS 26", plus the trigger runtime, plus the Slice 3 surfaces (search
palette, Hidden items tray, Settings with a trigger editor, trigger notifications, the notch
surface and timer, the wide-display rule), plus the Slice 4 fill-ins (Sparkle updates, item
spacing, real item images, the icon-change trigger, the notch's live activities, the
active-display rule). The search palette, the tray, the Items window's groups, Settings, the
drawn notch and the menu bar style were driven with synthetic input on 2026-09-27 (below); the
rest of what came after Slice 2 builds and is unit-tested but has not been opened. Last updated
2026-09-27 on macOS 26.4.1, Xcode 26.4.1, Swift 6.3.1, a Mac mini
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
  until the pointer leaves the bar and comes back. The ticks were posted in pixel units; wheel
  ticks in line units (what a mouse without precise deltas sends, about 1 per notch) needed 20
  notches for the 20 pt threshold. Fixed 2026-09-28: a line counts as 8 pt
  (`RevealGestureRecognizer.scrollPoints`, `App/GestureMonitor.swift`); three line ticks with
  Ghostty in front then logged `Gesture scroll: reveal`, one did not. The global monitor does not
  see a scroll on the bar while Somabar itself is frontmost.
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
  `Reconciler`, `Rehide`, `Menus`, `Items`, `Triggers`, `Displays`, and since Slice 4
  `Spacing`, `Updates`, `icons` and `activities`. Read with
  `/usr/bin/log show --last 5m --predicate 'subsystem == "app.somabar"' --info --style compact`.
  Only `.info` and above persist; `.debug` lines do not show up in `log show`.
- **Search palette and menu drill-down (2026-09-27).** `somabar://search` opens the palette
  (600 × 419 pt) while Ghostty stays frontmost; typed keys reach it and filter ("clean" leaves
  CleanShot X). → lists the selected item's menu (`Read 16 menu entries from
  pl.maketheweb.cleanshotx`, 9 from CodexBar, 2 from Proton Pass, shortcuts such as ⇧⌘5
  shown); typing filters the level ("ref" leaves Refresh); ↩ presses the entry (`Pressed menu
  entry CodexBar › Refresh`). ← at the start of the query and ⌫ on an empty one go back, with
  the old query restored (fully selected); ← mid-query moves the caret. ↩ on an item row opens
  it (`Opened com.steipete.codexbar with AXPress`, its menu drops). ⎋, a click outside and a
  click on the bar close the palette; the bar click also reveals, as any empty-bar click does.
  Pressing a menu entry used to crash (index out of range: `close()` empties the matches before
  the entry's title was read); fixed in `App/SearchPalette.swift`. No item on this bar has a
  submenu, so submenus were not opened.
- **Hidden items tray (2026-09-27).** `somabar://tray` opens it (460 × 227 pt) under the glyph,
  listing Hidden items with absent ones greyed out. A click on CodexBar revealed it and opened
  its menu through `AXPress`, and the tray closed. ⎋, a click outside, and a second
  `somabar://tray` close it. The `ItemMover.click` fallback was not needed and not exercised.
- **Groups (2026-09-27).** In the Items window, right-click › Add to Group › New Group made a
  group; its header shows glyph, name and count, folds (kept in `somabar.items.collapsedGroups`),
  and its ⇆ menu and right-click menu move it (`Saved the layout: Items: moved New Group to
  Tucked`, then `Drift … Shown→Tucked` and `Reconciled the bar (groups edited): moved 1`). The
  group glyph landed just left of Somabar's glyph in Shown, so the "NSStatusItem Preferred
  Position" default works. A click on the glyph opens the member row (108 × 133 pt); a click
  on a Tucked member there revealed and opened it. The group glyph used to be scanned as an
  unidentified item (10 items, 9 identified) and listed in the palette; the scan now leaves it
  out with Somabar's own windows (`App/Groups/SomabarController+Groups.swift`,
  `App/SomabarController+Scan.swift`), and scans read 9 of 9.
- **Settings (2026-09-27).** ⌘, with the glyph's menu open opens Settings (620 × 552 pt) and
  Somabar becomes frontmost. The Groups tab shows the name, the glyph field, "Members are in:
  Tucked" and the member list; the glyph field saved "star" on Return and the bar glyph changed.
  The glyph menu's Triggers submenu shows "No triggers in the layout file" and "Remember This
  Router (b0:39:56:0b:e1:e5)".
- **Settings, the other tabs and live changes (2026-09-28).** Driven through Accessibility
  (`AXPress` on the tabs, switches and pop-ups) and synthetic keys, on a copy of the layout.
  General, Hot Keys, Profiles (list, name field, "New items go to", the notch switches),
  Triggers and Advanced all render. Each change took effect without a relaunch: scroll-to-reveal
  turned on revealed on the next scroll down on the bar (`Gesture scroll: reveal`) and turned
  off did nothing; "Show dividers" off removed the divider line from the revealed bar and on
  brought it back; the notch guard switch rescanned (`Scanned the bar (notch guard off)`, then
  `on`); a trigger's switch in the Triggers tab re-evaluated (`Triggers holding (triggers
  edited): none`, and on again, holding with a pulse); "Remember This Router" saved it and the
  row shows "This network". A switch flipped and the window closed 40 ms later was saved at
  once (`Saved the layout: Settings: preferences`), not after the 0.8 s wait. The key recorder
  takes first responder in this menu-bar-only app ("Type shortcut…" focused) and logs `Hot keys
  off while Settings records a shortcut`; ⌘T reached it through `performKeyEquivalent` and was
  registered, ⌃⌥B was refused ("Already used for “Toggle hidden”"), ⌫ cleared it, and each
  ending re-registered every hot key. Recording used to go on after Somabar lost key status (a
  click in another app, or closing Settings mid-recording), leaving every hot key unregistered
  until Settings came back; it now stops when the window resigns key
  (`App/Settings/KeyRecorder.swift`), seen for both. That Carbon gets the combo back was read
  from the log only: synthetic keys never reach Carbon hot keys. A combo that saves registers
  twice (once on save, once when recording ends), which is harmless.
- **Drawn notch (2026-09-27).** With `drawnNotch: true` the log reads `Notch surface up (drawn
  notch at x=870, 180 pt wide)`; the window is 460 × 300 pt at the top centre. Compact showed the
  call activity (green dot, mic glyph, elapsed time) for `avconferenced`'s microphone.
  `somabar://timer?1` logged `Timer started: 1 min` and `Timer finished` and `Pulse: Time's up` 60 s later. Resting
  the pointer on the notch expands it: profile chips, the timer row, the activity rows and the
  Hidden items row. In Expanded, a click on a profile chip switched profile, the 5 min pill
  started a timer, and Pause, Resume and Cancel worked (`Timer cancelled`), all while another app
  was frontmost. An `external` trigger turned on by `somabar://set?demo=on` pulsed its name
  (`Pulse: Demo`).
- **Agent activity through the URL (2026-09-27).** With `agentSocket` on and `agentActivity`
  enabled in the profile, `somabar://agent?session=t1&state=working` logged `Agent working (1
  sessions)`; `needsYou` pulsed "somabar needs you" and added a row with the detail to Expanded;
  `done` pulsed "somabar finished"; `ended` left 0 sessions. Compact stayed on the call, which
  ranks higher.
- **Menu bar style (2026-09-27).** `Menu bar style on 1 displays`; the window sits at layer 23,
  0,0, 1920 × 30 pt, exactly over the bar, and a red tint with a hairline shows through the
  macOS 26 bar, lined up (screenshot).
- **Menu bar styles from Settings (2026-09-28).** In dark mode, a hairline alone put the
  layer-23 window up (`Menu bar style on 1 displays`) with a thin line along the bar's bottom
  edge; "System accent" at 30% turned the bar a more saturated blue (screenshot against the
  plain bar; the wallpaper here is blue too, so the difference is small); tint None with the
  hairline off removed the window. Each applied on the change. The colour picker and the
  strength slider were not driven (the slider refuses `AXValue`).
- **Spacing (2026-09-28).** Snug wrote `NSStatusItemSpacing` 12 and
  `NSStatusItemSelectionPadding` 8, Tight 6 and 6 (`defaults -currentHost read -g`); Default
  removed both; with 10 and 10 set by hand, Default logged `Left item spacing alone … was not
  set by Somabar` and they stayed. The notice ("Spacing applies to apps opened from now on",
  OK and Log Out…) showed on the first Snug only; `spacingNoticeShown` was saved and later
  Snug and Tight picks showed nothing. A quit through an Apple event logged `Item spacing set
  to default, system default (quit)` and both keys were gone. Log Out… was not pressed.
- **Trigger notifications (2026-09-28).** Turning "Notify when a trigger fires" on showed
  macOS's own request as a banner ("“Somabar” Notifications: Notifications may include
  alerts, sounds, and icon badges.") on this ad-hoc build; it was left unanswered, since the
  answer would stick to the real app's bundle ID. While it waits, `requestAuthorization` does
  not return (no `Notification permission:` line) and the toggle stays on. `somabar://set?
  demo=on` pulsed the notch (`Pulse: Demo from a script`) and `usernoted` accepted the
  notification into Notification Center's list (`Delivering <NotificationRecord
  app:"app.somabar.Somabar" …>`); no banner showed. The request showed a blank app icon.
- **The reconciler retries after waiting for input.** A pass that gave up because the pointer
  rested on the bar (`Bar not idle … reconciling later`) was never scheduled again; it now
  rescans 2 s later (`App/SomabarController+Layout.swift`).
- **Corrupt layout file (2026-09-28).** A directory whose `layout.somabar` held 31 bytes of
  garbage logged `Could not read the layout file … Starting from defaults` and `Moved the
  unreadable layout file to layout.broken-1790616153.somabar`; the first scan saved a fresh
  file (`Learned from the bar`, Everyday with 5 Shown items) that decodes.
- **Time-of-day triggers (2026-09-28).** Two triggers on a copy of the layout: 22:54–22:56
  show CodexBar (Hidden in Everyday and Focus), 22:54–22:57 switch to Focus. At 22:54:00.1
  the minute tick logged both holding, `Switched to profile Focus by trigger` (saved with
  `profileBeforeTriggers` Everyday) and `Triggers apply: show [com.steipete.codexbar]`; the
  reconciler moved 3 items in 3 s and CodexBar stayed Shown, while Focus in the file kept it
  Hidden. At 22:56:00.1 the show ended and CodexBar went back to Hidden; at 22:57:00.3 `Trigger
  ended; back to profile Everyday`, `profileBeforeTriggers` cleared, 2 items moved back. The
  window's end minute is exclusive.
- **The "Triggers" submenu with triggers (2026-09-28).** Opened by a right-click on the glyph
  and arrow keys. While both held it read "Holding: Clock shows CodexBar", "Holding: Clock
  focus", "Back to Everyday when the trigger ends" and "Remember This Router (…)"; after
  22:56 only the focus line and "Back to Everyday"; after 22:57 "No trigger holds right now".
  The Profile submenu ticked Everyday again. A plain left click on the glyph reveals; the menu
  needs a right click (or ⌃-click).
- **Rehide when the app changes (2026-09-28).** After `somabar://reveal`, activating Finder
  hid the bar 1.06 s later (`Rehide timer fired; hiding`), well inside the 8 s timer.
- **Show everything above N points (2026-09-28).** With `showEverythingAbovePoints` 1000 the
  launch logged `Active display 1920 pt, show all above 1000 pt (launch): showing Hidden and
  Tucked items` and moved CleanShot X and CodexBar Hidden→Shown; the file kept them in Hidden.
  A synthetic ⌘-drag of Caffeine left of the revealed Hidden divider was learned into Hidden
  at the next scan, but the item stayed in Hidden on the bar until some later scan happened
  to notice the drift (23 s later, only because of a `somabar://rescan`). Now the scan that
  learns the move also moves it back (`Learned, but the display rule keeps them in the bar`,
  then `Moved net.domzilla.caffeine: Hidden → Shown` 2 s later;
  `App/SomabarController+Layout.swift`, `overriddenDrifts`). The HID drag crossed the
  divider only when slow (60 steps, 0.6 s pauses); a 20-step drag landed the item at the left
  end of Shown, and the layout learned only the new order.
- 331 unit tests in 62 suites pass (`swift test`); `swiftlint` is clean; the app target builds
  with no warnings.

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
- **Multiple displays.** The bar Somabar moves items on is the primary display's; the display
  rules now read the active display (below), the tray and the notch surface prefer the
  built-in display. None of it has been tried with a second display attached.
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
- **Time-of-day windows across midnight** and a person picking a profile by hand while a
  time-of-day trigger holds one are unit-tested only; edges within a day were seen (above).
- **`knownRouter` conditions** ran only in unit tests; "Remember This Router" was seen in the
  Triggers submenu but not pressed.
- **Search palette and tray** were driven with synthetic keys and clicks (above). Not seen:
  where the tray lands on a notched or multi-display Mac, the hot keys (⌃⌥/, ⌃⌥↓), submenus
  in the drill-down, and a real keyboard and pointer. On 2026-09-28 "codex" then → listed
  CodexBar's menu (9 entries read). Its only two submenus hold a single untitled custom view
  (a chart), which the reader leaves out, so they show as plain entries without a chevron and
  → does nothing. No running item here has a submenu with titled entries, so drilling into
  one is still unseen. "Items…" no longer shows ⌃⌥/; that
  shortcut now belongs to "Search Items…".
- **Opening an item from the palette or tray** uses `AXPress` with a 0.5 s timeout and treats a
  timeout as success, because some apps answer only once their menu closes. Without an element
  it clicks the item's window through `ItemMover.click` after waiting up to 1.2 s for the
  revealed item to settle. The `AXPress` path opened CodexBar from the palette, the tray and a
  group row; the click fallback has not run. Apple's, hosted and unidentified items only get
  the pointer. On macOS 26 the fallback could not be provoked (2026-09-28): an identified item
  always has its element (identification is the Accessibility match), and a test app's status
  item answered `AXPress` with success even when its button refused the press
  (`accessibilityPerformPress` false, the selector disallowed) and no mouse-down arrived. So an
  app that opens its menu only on a real mouse-down would be logged as opened with `AXPress`
  while nothing opens. A test item drawn by a custom view (`NSStatusItem.view`) was classed
  hosted ("managed" in the palette), and ↩ only pointed at it.
- **Settings window.** Builds, and its editing rules are unit-tested (hot key clashes, profile
  rename/remove/add, condition editor round trips, the `notifyWhenTriggerFires` default and
  round trip). Every tab, the live changes, save on close and the key recorder were driven
  (above). Edits are saved 0.8 s after the last change, and whatever is still waiting is saved
  when the window closes. Not seen: a real key press recorded (synthetic keys reached the
  recorder but can't show Carbon taking the combo back), hover gestures and the rehide sliders
  changed live, profile add/remove/rename from the tab, and the trigger editor sheet.
- **Spacing (M10).** Snug writes `NSStatusItemSpacing` 12 and `NSStatusItemSelectionPadding`
  8, Tight 6 and 6, into the current-host global domain through `CFPreferences`; Default
  removes the keys, but only when they hold one of Somabar's pairs, so values a person set by
  hand stay. Applied at launch and on each change, removed on a normal quit (M19; after a
  crash they stay until the next launch reconciles them). The first non-default pick shows one
  alert ("Spacing applies to apps opened from now on", OK and Log Out…), remembered in
  `spacingNoticeShown`. The keys, Default's rule, the quit and the single alert were seen
  (above). Not seen: that newly launched apps pick the values up, that a log-out applies them
  everywhere, and the Log Out… path with its Automation prompt.
- **Updates.** Sparkle 2.10 is linked into the app target only. The updater starts only when
  `SUFeedURL` and `SUPublicEDKey` are both non-empty in Info.plist; the key is empty in this
  tree, so "Check for Updates…" is disabled with a tooltip and Settings › General › Updates
  shows the toggle disabled with a note, and nothing touches the network. `codesign --verify
  --deep --strict` passes on the built app with the embedded framework. Not seen: Sparkle
  loading under ad-hoc signing and the hardened runtime, the first-launch question, and an
  update end to end with a real key and appcast.
- **Real item images.** With `realItemImages` on and Screen Recording granted, each status
  window is captured once with `SCScreenshotManager` (no streams), cached by window ID and
  refreshed after a scan whose set of windows changed or whose last capture is over 60 s old.
  Blank captures fall back to the app icon. Turning the toggle on calls
  `CGRequestScreenCaptureAccess` once; Settings re-checks the permission when the window
  appears or the app becomes active. Not seen: whether hidden items' off-screen windows
  capture, the prompt, "Open System Settings", how long the purple indicator shows, and
  whether `CGPreflightScreenCaptureAccess` reports a fresh grant before a relaunch. The
  palette and tray only pick up new captures the next time they open.
- **Icon-change trigger.** "Item icon changes" is an editor condition; saving an enabled
  trigger that uses it asks for Screen Recording once, ever (a UserDefaults flag). The
  detector runs on the existing 3 s status-window pass, captures only the watched items,
  compares a 16 × 16 coverage-and-colour hash (40/255 per pixel, more than 5 of 256 pixels)
  and reports changes into `ContextSnapshot.changedIcons`, which holds for 10 s. It is
  skipped while a menu hangs from the bar or a reconcile runs. Not seen: hash sensitivity
  on real icons (menu highlight, clock-like items, wallpaper tint) and whether a click on a
  watched item trips it through its highlight.
- **Live activities.** `ActivityBoard` (NotchKit, unit-tested) ranks Call > Timer in its last
  60 s > Transfer > Now Playing > Timer, filters by the profile's `enabledActivities`, and
  leaves only Call and Timer while the screen is shared. Built: Call (green dot, mic or
  camera glyph, elapsed time; the app name for Zoom, Teams, FaceTime, Webex, Slack, Discord,
  else "Browser call"; no mute or hang-up), Charging (a pulse with percent and time to full
  from IOKit, waiting up to 4 s for the estimate), Drop to share (a global drag monitor
  during file drags, a clear panel over the widened notch, `NSSharingServicePicker` on drop),
  Now Playing (Music and Spotify distributed notifications; AppleScript for Music's position
  and artwork and for previous/play-pause/next, so Automation is asked once and the app
  gained the apple-events entitlement and usage string; no scrubber or output picker), a
  Focus pulse and the screen-share red dot with "Back to <profile>". Expanded shows at most two
  activity rows; a third live activity (here Transfers, under a mic call and an agent) is
  left out until one ends. This Mac has no battery, camera or notch.
  Seen on the drawn notch on 2026-09-28. Drop to share: a synthetic drag of a file from a
  Finder list onto the notch logged the drag, widened Compact to the share glyph, and on
  release opened the share menu (AirDrop, Mail, Messages…, Copy) hanging from the notch. It
  stayed open until Escape. One earlier run showed no menu 2.5 s after the drop, cause
  unknown. Now Playing: the Music library is empty, so Music, its `playerInfo` fields and the
  Automation prompt are not seen. A hand-posted `com.spotify.client.PlaybackStateChanged`
  showed the Expanded row (title, artist, time left, scrubber, previous/pause/next); the
  controls were not pressed, since Spotify is not installed.
- **Active-display rule.** With `leaveInactiveDisplaysUntouched` (default) the width rule
  reads the display whose menu bar is active (`NSScreen.main` when displays have separate
  Spaces, else the primary display), re-read on app activation, Space change and display
  change; off, the widest display as before; an unknown width falls back to the widest.
  Unit-tested, not tried with two displays.
- **Trigger notifications.** `.somabarTriggerFired` is posted when a trigger starts holding or
  switches profile; when the person asks for it, a system notification follows, but not at
  launch. On this ad-hoc build the permission request appears and notifications reach
  Notification Center while it is unanswered (above). Not seen: a banner after Allow, the
  refusal path (toggle back off with the note), and whether the banner shows while Settings is
  in front. The notch pulse it drives was seen.
- **The notch surface around a real camera has not been seen.** This Mac has no notch, so only
  the drawn notch was watched (above). The camera-housing layout (56 pt of compact beside the
  camera, 80 pt for a pulse, truncated pulse text) and the choice of the built-in display when
  it has a notch are assumed. Hover intent, first clicks on the panel and the click-through of
  the transparent canvas (`ignoresMouseEvents` toggled on pointer moves) worked with synthetic
  events; a real trackpad has not tried them. The surface is rebuilt on a screen-parameters
  change only when the notch geometry changed, and a running timer carries over; neither has
  been exercised. The hot key for the 25-minute timer is unassigned by default; without a
  surface (no notch and `drawnNotch` off) it and `somabar://timer` only log a notice.
  Expanded's Hidden items row follows the profile's `hiddenItemsTray` switch, which did
  nothing before (checked in Focus, where it is off, and Everyday, where it is on).
- **Show everything above N points** is applied in `effectiveLayout` (display rule first, then
  triggers, so a trigger's hide still wins) and unit-tested. It held on this 1920 pt display
  only with the threshold lowered to 1000 (above). Not seen: a real wide display, the rule
  letting go (items going back to Hidden) without a relaunch, a trigger's hide winning while it
  holds, and a hand drag (the drag was synthetic).
- **Groups (M9).** Model, editing and the keep-together rule are unit-tested (26 tests). Each
  group gets its own status item, placed through the undocumented "NSStatusItem Preferred
  Position" default (seen working, above). The glyph field saves on Return. Not seen: a
  member's ⌘-drag pulling the group along, a letter glyph.
- **Item hot keys.** Registered with the action hot keys through Carbon; clashes are checked
  both ways and unit-tested. Not seen: a real key press opening an item or group.
- **Transfers.** A file-system event source on Downloads plus `Progress.addSubscriber`; a 1 s
  refresh only while something is live. One Expanded row covers all downloads, since rows are
  keyed by activity kind. Not seen: the Downloads access prompt, which path Safari and Chrome
  publish progress for, finish detection per browser. Checked on 2026-09-28 with a script that
  writes a file in Downloads while publishing an `NSProgress` (kind file, downloading,
  cancellable), and one that only grows a file. Two fixes:
  - Published progress was never matched. In the subscriber's handler the proxy's `fileURL`
    is still nil; the URL is in `userInfo[.fileURLKey]`
    (`App/Notch/Activities/TransfersWatcher.swift:141`).
  - Expanded was capped at 300 pt by `NotchGeometry.maxExpandedSize`, which cut off the third
    line, the "and N more" footer and the Hidden items row. It is now 600 pt, the worst case
    of two rows with full lines.
  Since the fixes, five downloads showed "5 downloads" with four lines and "and 1 more". The
  published lines show percent, "of 20 MB", time left, a bar, Show in Finder and Cancel; the
  plain file shows only its size. Cancel reached the publishing process, which deleted its
  file, and the line went without a "Downloaded" pulse. Each finish was logged, including the
  plain file about 3 s after its last write. The Expanded panel has about 40 pt of empty space
  at the bottom with lines shown.
- **Volume HUD.** CoreAudio listeners plus an event tap that consumes the volume keys when the
  activity is on, a notch surface exists and Accessibility is trusted; otherwise the keys pass
  through. The pulse lasts the machine's fixed 2 s, is dropped while Expanded, and plays no
  feedback sound. Not seen: that the tap suppresses the macOS 26 overlay, AirPods and HDMI.
- **Agent activity.** A Unix socket (folder 0700, socket 0600, same-user peer with a valid
  signature, read-only) and `somabar://agent`, both off until "Listen for coding agents" is on.
  Sessions expire after 10 min. The socket sits beside the layout file, so
  `SOMABAR_DOCUMENT_DIR` moves it too. The path must stay under 104 bytes (`sun_path`), so a
  long `SOMABAR_DOCUMENT_DIR` needs a short symlink. On 2026-09-28 a headless `claude -p`
  (haiku) session, with the repo's hook script on every event, showed "proj" working, then
  needing you, then finished; its terminal was taken as Ghostty. Not clicked: "Show terminal".
- **Agent permission prompts (P2).** Off unless both "Listen for coding agents" and "Answer
  permission prompts from the notch" (`agentReplies`, default false) are on. A hook sends
  `{"request","session","tool","detail"}` on the socket and keeps the connection open; Somabar
  writes one line `{"id","decision":"allow|deny|ask"}` to that connection and closes it.
  `somabar://` never answers. "ask" (the agent asks in its terminal) on a 60 s timeout, "Answer
  in terminal", the session finishing or ending, the switch off, a full queue (8, 4 per
  session) and socket stop; the hook closing drops the prompt. The agent row lists the oldest
  prompt per session (at most 2, then "and N more waiting") with Allow, Deny and Answer in
  terminal; Allow is ignored for 1 s after a prompt appears and not offered where the profile
  hides file names. `Sources/NotchKit/AgentPrompts.swift` (parsing, `AgentPromptQueue`),
  `AgentSocketServer` request/reply, `AgentChannel`; `somabar-agent-hook.sh ask` prints Claude
  Code's `PermissionRequest` (or `PreToolUse`) decision JSON, or nothing. Unit-tested; the hook
  was run against the real `AgentSocketServer` outside the app (allow, deny, ask, switch off,
  stop, hook killed). Seen on 2026-09-28 with headless `claude -p` (haiku, a Write in a
  scratch folder): the `PermissionRequest` hook fires in `-p` mode.
  - The agent row read "proj needs you", with a "proj · Write" line, the path, and Allow, Deny
    and terminal buttons.
  - Allow wrote the file.
  - Deny made Claude Code report the tool as denied.
  - Leaving the prompt for 60 s logged the timeout and answered "ask". Headless Claude Code
    then refused the tool and asked for permission in its reply.
  Not seen: whether interactive Claude Code shows its terminal prompt while the hook waits.
  Headless mode has none.
- **Release pipeline.** `SUFeedURL` and `SUPublicEDKey` come from `SPARKLE_FEED_URL` and
  `SPARKLE_PUBLIC_ED_KEY` in `Config/Somabar.xcconfig`; the key is empty there and set only in
  the untracked `Config/Release.local.xcconfig`, so builds from the tree keep updates off.
  `make release` (`Scripts/release.sh`) makes a universal Release build without
  `get-task-allow`; with `SOMABAR_SIGN_IDENTITY` it re-signs Sparkle's helpers, the framework
  and the app with the Developer ID, hardened runtime and timestamps; with
  `SOMABAR_NOTARY_PROFILE` it notarizes, staples and checks with `spctl`. It writes
  `dist/<version>/updates/Somabar-<version>.zip` and a dmg, extends the published appcast with
  `generate_appcast` (keychain key or `SPARKLE_ED_KEY_FILE`), refuses a build number that is
  not newer, and checks the zip's EdDSA signature against the app's key with CryptoKit. Steps
  without credentials are skipped with a note. `Scripts/sparkle-keys.sh` wraps `generate_keys`
  (`--write`, `--print`, `--export`); `.github/workflows/release.yml` does the same on a `v*`
  tag from secrets. Seen: an ad-hoc release with the key empty (no appcast, updater off), and
  appcasts for 0.1.0 and 0.1.1 signed with a throwaway key file, both entries kept. Not seen:
  `generate_keys`, Developer ID signing, notarization, stapling, a published appcast, the
  workflow, an update end to end.
- **Menu bar style (M13).** A click-through window per display just below the menu bar draws
  the tint and hairline; seen on this display (above), a colour tint, the accent tint and a
  hairline alone, the last two in dark mode. Not seen: notched and external displays, auto-hide, light
  mode and a switch between the two, the colour picker.
- **Call and Now Playing controls.** Mute uses the default input device's CoreAudio mute (it
  mutes every app) and is undone at call end; hang-up presses the call app's own menu item
  through Accessibility, never "End Meeting". The scrubber seeks through AppleScript; the
  output picker sets the default output device. Not seen on real call apps, devices or players.

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
  It does not move the user defaults (`app.somabar.Somabar`: folded groups, group glyph
  positions), which stay the real app's. It does move the agent socket, which must stay under
  104 bytes.
- **Synthetic input limits found on 2026-09-27.** A synthetic click on an item of a SwiftUI
  context menu does not register (↓ and ↩ do); text typed right after a click into a SwiftUI
  text field is lost until the field has focus. System Events reports the wrong frontmost app
  for Somabar; `NSWorkspace.frontmostApplication` is right. A synthetic click left on the bar
  keeps the pointer there, and the reconciler waits for it to leave.

## Not built yet

Nothing in code. The owner still has to create the Sparkle key and the notary profile and
publish a first appcast (README › Releasing); until then the tree ships an empty
`SUPublicEDKey` and updates are off.

The controller was split into `SomabarController+Reveal`, `+Scan` and `+Menu`; its class
body is 216 lines.

## Built since the last verified run (2026-09-26)

- **Menu drill-down in search (1.1).** In the palette, → at the end of the query lists the
  selected item's menu, read closed through Accessibility (the `AXMenu` under its
  `AXMenuBarItem`, submenus up to 6 deep). Typing filters the current level and every submenu
  below it with `ItemSearch` ranking; deeper matches show their path. → or ↩ opens a submenu,
  ↩ presses an entry with `AXPress`, ← at the start of the query or ⌫ on an empty one goes back.
  Apps that build their menu only when clicked (Caffeine), macOS's own items and unidentified
  items show a note. `Sources/SomabarCore/MenuDrillDown.swift`,
  `Sources/BarEngine/StatusMenuReader.swift`, `App/SearchPaletteMenus.swift`; the shared panel
  moved to `App/SomabarPanel.swift`. Key handling was run on 2026-09-27 (see *Verified*).
- **Groups in the Items window.** Each section lists its groups under headers (glyph, name,
  count), members in bar order, then ungrouped items (`GroupedItems` in SomabarCore). Groups
  fold (kept in user defaults) and move to Shown, Hidden or Tucked from the header or the
  right-click menu: the layout changes, then the rescan and reconciler move the members.
  Right-clicking an item adds it to a group or a new group, or takes it out. Moves are disabled
  without Accessibility access. Run on 2026-09-27 (see *Verified*).
- **One Expanded row per download.** Several downloads show a summary row and a line each
  (name, bytes and time left, bar, Show in Finder, Cancel when the `NSProgress` is
  cancellable), at most 4 then "and N more"; one download is the row itself.
  `TransferLines` and `TransferText.timeLeft` in `Sources/NotchKit/Transfers.swift`. Expanded
  can reach about 490 pt with two activities and four lines.
- **Log Out in the spacing notice.** "Log Out…" confirms, then runs `tell application "System
  Events" to log out`; a refused Automation permission is explained.
  `NSAppleEventsUsageDescription` now mentions it.

- Slice 4: `App/Updates/` (Sparkle 2, the Updates settings section), `App/Spacing/` (the
  spacing defaults and the notice; `Spacing` in SomabarCore knows its values),
  `App/ItemImages/` (Screen Recording permission, one-shot window capture, the image
  provider, the icon-change detector; `Sources/SomabarCore/IconChange.swift` holds the
  watched-items rule and the hash), `App/Notch/Activities/` (`ActivityCenter`, the
  charging, Now Playing and drop-to-share watchers, the activity views;
  `Sources/NotchKit/ActivityBoard.swift`, `ActivityText.swift` and `NowPlayingTrack.swift`
  are the pure parts), `App/Context/ActiveDisplay.swift` with
  `ContextSnapshot.activeDisplayPoints`. Preferences gained `spacingNoticeShown`; `project.yml`
  gained the Sparkle package, `SUFeedURL`, an empty `SUPublicEDKey`, the apple-events
  entitlement and `NSAppleEventsUsageDescription`.

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

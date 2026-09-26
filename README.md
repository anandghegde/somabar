# Somabar

A free, open-source menu bar and notch manager for macOS 26. Somabar hides the items you
don't need, reveals them on a click, a scroll, a hover or a hot key, and remembers where
everything goes.

Licence: GPL-3.0. See the product requirements document for the full design.

## Status

Slice 2, "engine alpha". Somabar can:

- Put its glyph and two dividers in the menu bar. Items left of a divider are hidden by
  inflating the divider (macOS caps it near 5,000 pt), the way Hidden Bar does it.
- Reveal hidden items on a click of the glyph, a click on the empty menu bar, or ⌃⌥B, and
  hide them again after 8 seconds, when the front app changes, or on a second click.
  ⌥-click on the glyph reveals the Tucked section too. Scrolling down on the bar and
  hovering over the empty bar are available as reveal gestures, off by default.
- Wait while a menu is open: the auto-rehide timer holds until the menu closes, then hides
  the bar shortly after.
- Move items itself. With Accessibility access it ⌘-drags items between sections so the bar
  matches your layout: switching profiles rearranges the bar, a new app's item goes where
  the profile says (Shown for Everyday, with a dot on the glyph until you look), and an
  item that drifted while Somabar was not looking is put back.
- Learn from you: ⌘-drag an item yourself and the layout follows.
- Switch profiles (Everyday, Presenting, Focus) from the glyph's menu, ⌃⌥P or a URL.
- Leave Apple's own items alone, including the ones Control Center hosts for agents such as
  Screen Sharing.
- Save the layout as JSON with a 20-entry history, and put every item back in view when it
  quits.
- Run triggers: *when* on battery, on an unknown network, sharing the screen, in a Focus, at
  a time of day, with an app in front, or told to by a script, *then* show or hide an item or
  switch profile, *until* the condition ends. See below.
- Search every item from the palette (⌃⌥/, "Search Items…" in the glyph's menu, or
  `somabar://search`). Type to filter by app name or title; ↑/↓ and ↩ open the item: Somabar
  reveals its section and opens its menu through Accessibility, or clicks it. Apple's own
  items and ones Somabar can't identify are listed, but Somabar only points at them.
- Open the Hidden items tray (⌃⌥↓, "Hidden Items Tray…", or `somabar://tray`): the Hidden and
  Tucked items as app icons with titles under the menu bar, without revealing the bar. Click a
  tile to open that item. With `displayRules.trayOnlyOnBuiltInDisplay` it opens on the
  built-in display.
- Be set up in Settings (⌘, in the glyph's menu, or `somabar://settings`): gestures, rehide,
  hot keys with a recorder that refuses clashing combos, profiles, a trigger editor, known
  routers, the notch, and a notification when a trigger fires.
- Draw a notch surface around the camera housing, or around a drawn 180 × 32 pt notch on a
  display without one (`drawnNotch`, off by default; the whole surface is `notchSurface`). It
  stays invisible until something happens. A running timer sits beside the camera, and a
  trigger firing, a new item or the timer ending shows for 2 s. Resting on the notch or
  clicking it opens a panel with the profiles, the timer and the Hidden items; it springs
  open, or fades in Still Mode, and closes when the pointer leaves.
- Run a notch timer: 5, 25 or 50 minutes from the panel, the "Start 25-minute timer" hot key
  (unassigned by default), `somabar://timer?25` or `somabar://timer?stop`. It shows m:ss
  beside the camera and pulses "Time's up".
- Show everything on a wide display: above `displayRules.showEverythingAbovePoints` (2560 pt
  by default, `null` turns it off), Hidden and Tucked items stay in the bar without changing
  the layout file. The log's `Displays` category records the decision.

Not yet: updates, rules for more than one display beyond the width rule, and the `spacing`
preference (saved, not applied). The notch guard and the notch surface have not been
exercised on a notched Mac, and none of the new windows has been opened by hand yet; see
`implementation_status.md`.

## Requirements

- macOS 26 (Tahoe). Other versions get the glyph and a message.
- Xcode 26.4 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build the app.
- Accessibility access, to identify and move items. Without it Somabar still hides and
  reveals, but adopts the bar as it is.

## Build

```sh
make test      # unit tests for SomabarCore, BarEngine, NotchKit
make lint      # swiftlint
make app       # xcodegen + xcodebuild into .build/xcode
make run       # build and launch
```

The app is ad-hoc signed, so macOS forgets its Accessibility permission on every rebuild.
Grant it again from the glyph's menu, or launch the binary from a terminal that already has
the permission and it inherits the trust:

```sh
.build/xcode/Build/Products/Debug/Somabar.app/Contents/MacOS/Somabar &
```

Only one copy runs at a time. Launching a second one, from either command, prints "Somabar is
already running (pid N)" and quits, leaving the first in place. Quit the running copy from the
glyph's menu before launching a rebuilt one.

## Settings

Everything below can be set in Settings (⌘, in the glyph's menu, or `open
"somabar://settings"`): reveal gestures, auto-rehide, Still Mode, dividers and spacing under
General; a recorder per action under Hot Keys, which refuses a combo another action or macOS
already uses; profile names, where new items go and what the notch shows under Profiles;
triggers under Triggers; known routers, item images, the notch and "Notify when a trigger
fires" under Advanced. Edits are saved 0.8 s after the last change.

The tables here remain the file format. Preferences live in the layout file under
`preferences`; quit Somabar before editing the file by hand, since it saves the file itself
when something changes.

| Key | Default | Meaning |
| --- | --- | --- |
| `revealGestures.clickEmptyBar` | true | A click on the empty bar reveals; another hides. |
| `revealGestures.scrollDownOnBar` | false | Scrolling down on the bar reveals; up hides. |
| `revealGestures.hoverEmptyBar` | false | Resting on the empty bar reveals. |
| `revealGestures.hoverDelayMilliseconds` | 300 | How long the pointer rests first (0–800). |
| `rehideAfterSeconds` | 8 | Auto-rehide; 0 turns it off. |
| `rehideWhenMenuCloses` | true | Hide 0.4 s after a menu closes, instead of waiting out the timer. |
| `rehideWhenAppChanges` | true | Hide when the front app changes. |
| `stillMode` | false | Never auto-rehide; the notch fades instead of springing. |
| `showDividers` | true | Draw the two dividers in the bar. |
| `notchSurface` | true | Draw the notch surface at all. |
| `drawnNotch` | false | On a display without a notch, draw a 180 × 32 pt one to hang the surface on. |
| `notchGuard` | true | Move Shown items that would sit under the camera housing to Hidden. |
| `realItemImages` | false | Reserved: real item images need Screen Recording; off means app icons and titles. |
| `notifyWhenTriggerFires` | false | Show a system notification when a trigger starts holding or switches profile. |
| `displayRules.showEverythingAbovePoints` | 2560 | Keep every item in the bar on a display wider than this; `null` turns it off. |
| `displayRules.trayOnlyOnBuiltInDisplay` | true | Open the tray on the built-in display when there is one. |
| `knownRouters` | [] | Hardware addresses of routers the `knownRouter` condition trusts. |

## Triggers

A trigger is *when [condition], [show item / hide item / switch profile], until [condition
ends]*. Triggers are made in Settings › Triggers: a name, a condition built from one or more
of the conditions below combined as all / any / none, and an action picked from the items
Somabar knows or the profile list. Conditions nested deeper than that stay editable in the
file, and the editor leaves them as they are. When "Notify when a trigger fires" is on, macOS
shows "Docker from a script is holding" or "Switched to Presenting by Present when sharing"
as the trigger fires.

In the file, triggers live under `triggers`. Each has an `id` (any UUID), a `name`,
`isEnabled`, a `condition` and an `action`. Items are named the way the rest of the file
names them: `{"bundleID": "com.docker.docker", "title": "…", "ordinal": 0}`, copied from a
profile's layout.

```json
{ "id": "…", "name": "Battery when unplugged", "isEnabled": true,
  "condition": {"powerSource": {"_0": "battery"}},
  "action": {"show": {"_0": {"bundleID": "com.apple.controlcenter", "title": "Battery", "ordinal": 0}}} }

{ "id": "…", "name": "Present when sharing", "isEnabled": true,
  "condition": {"screenSharing": {}},
  "action": {"switchProfile": {"name": "Presenting"}} }

{ "id": "…", "name": "VPN on unknown Wi-Fi", "isEnabled": true,
  "condition": {"allOf": {"_0": [{"network": {"_0": {"wifi": {}}}}, {"network": {"_0": {"unknownNetwork": {}}}}]}},
  "action": {"show": {"_0": {"bundleID": "io.tailscale.ipn.macos", "title": "Item-0", "ordinal": 0}}} }

{ "id": "…", "name": "No Slack after 19:00", "isEnabled": true,
  "condition": {"timeOfDay": {"_0": {"fromMinute": 1140, "toMinute": 420}}},
  "action": {"hide": {"_0": {"bundleID": "com.tinyspeck.slackmacgap", "title": "Item-0", "ordinal": 0}}} }

{ "id": "…", "name": "Docker from a script", "isEnabled": true,
  "condition": {"external": {"name": "docker"}},
  "action": {"show": {"_0": {"bundleID": "com.docker.docker", "title": "Item-0", "ordinal": 0}}} }
```

Conditions: `powerSource` (`battery`, `adapter`), `batteryBelow` (`{"percent": 20}`),
`network` (`ethernet`, `wifi`, `vpn`, `knownRouter`, `unknownNetwork`, `offline`), `display`
(`builtInOnly`, `externalConnected`, `widerThan` with `{"points": 2000}`), `screenSharing`,
`mediaInUse` (`microphone`, `camera`, `either`), `appRunning` and `appFrontmost`
(`{"bundleID": "…"}`), `focus` (`{"name": "Work"}`), `timeOfDay` (minutes since midnight; a
range that ends before it starts crosses midnight), `external` (`{"name": "docker"}`), and
`not`, `allOf`, `anyOf` to combine them. Actions: `show`, `hide`, `switchProfile`.

How they behave:

- Show and hide never change your layout. While the condition holds the bar shows the effect;
  when it ends the item goes back where the profile says.
- A profile switch remembers the profile it left and goes back to it when the condition ends.
  Pick a profile yourself while a trigger holds one and yours stays.
- ⌘-drag an item a trigger is holding and the trigger leaves it alone until its condition ends
  and starts again.
- Several triggers on one item: show beats hide. Several profile triggers: the last one in the
  file wins.
- *Known router* means the router's hardware address is in `preferences.knownRouters`. The
  glyph's menu has "Triggers › Remember This Router" for the network you are on.
- *Screen sharing* is read off the bar: macOS shows a Screen Sharing item while someone is
  viewing the screen. Zoom and other apps that record the screen are not detected.
- *Focus* needs a Focus Filter: System Settings › Focus › (a Focus) › Focus Filters › Add
  Filter › Somabar, then type the name your trigger uses.
- `external` conditions are switched from outside: `open "somabar://set?docker=on"` and
  `open "somabar://set?docker=off"`; several at once with `&`. Names are case-insensitive.

The glyph's menu shows which triggers hold under "Triggers". The log (below) has a
`Triggers` category with every context change and effect.

## Layout

| Directory | What it holds |
| --- | --- |
| `Sources/SomabarCore` | Layout model, profiles, gestures and rehide rules, persistence. Pure Swift, unit-tested. |
| `Sources/BarEngine` | One backend per macOS version, discovery, input safety, the item mover. |
| `Sources/NotchKit` | Notch state machine, hover intent and the notch timer. |
| `App` | The menu bar app: glyph, menu, hot keys, gestures, reconciler, Items window, search palette, tray. |
| `App/Settings` | The Settings window and the trigger editor. |
| `App/Notch` | The notch surface window, its views and model. |

Your layout lives in `~/Library/Application Support/Somabar/layout.somabar`. Set
`SOMABAR_DOCUMENT_DIR` to run a copy against another directory, for instance to try triggers
on a copy of the file.

## URL scheme

`somabar://toggle`, `somabar://reveal`, `somabar://reveal?tucked`, `somabar://hide`,
`somabar://items`, `somabar://search`, `somabar://tray`, `somabar://settings`,
`somabar://rescan`, `somabar://profile?Focus`, `somabar://timer?25`, `somabar://timer?stop`,
`somabar://set?docker=on`, `somabar://set?docker=off&meeting=on`.

## Logs

```sh
/usr/bin/log show --last 5m --predicate 'subsystem == "app.somabar"' --info --style compact
```

See `implementation_status.md` for what has been verified on a real bar and what has not.

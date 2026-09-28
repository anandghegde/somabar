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
  the layout file. The log's `Displays` category records the decision. With
  `displayRules.leaveInactiveDisplaysUntouched` (on by default) the rule follows the display
  you are working on, so a wide display nobody is using does not change the bar; off, it
  looks at the widest display.
- Show live activities in the notch, one at a time: a call (green dot and call length), a
  timer in its last minute, what Music or Spotify is playing, then a running timer. Hover to
  see up to two more, with previous, play/pause and next for the player. Plugging in the
  charger pulses the charge level and time to full; a Focus change pulses too. Drag a file
  anywhere and the notch widens into a drop target; drop it to open the share menu, AirDrop
  included. While the screen is shared the notch shows a red dot and only calls and timers.
  Each profile chooses which activities it shows (Settings › Profiles). The first time
  Somabar reads Music or Spotify, macOS asks for Automation access.
- Tighten the spacing between items (Settings › General): Default, Snug or Tight. Somabar
  sets macOS's `NSStatusItemSpacing` and `NSStatusItemSelectionPadding` for your user on
  this Mac. Apps opened from then on use the new spacing; log out and back in to apply it to
  every item. Somabar explains this once, and puts spacing back to the system default when it
  quits.
- Show real item images in the palette and the tray (`realItemImages`, off by default), captured
  with one-shot ScreenCaptureKit screenshots. Somabar asks for Screen Recording when you turn
  it on; without it, or when a capture fails, it shows the app's icon as before.
- Run a trigger when an item's icon changes ("Item icon changes" in the trigger editor). It
  needs Screen Recording, which Somabar asks for once when such a trigger is saved. See
  Triggers below.
- Check for updates through Sparkle 2 ("Check for Updates…" in the glyph's menu, automatic
  checks under Settings › General). The update check is the only network call Somabar makes.
  Builds without a signing key, including every local build, have updates switched off.

- Group items (Settings › Groups): up to 8 items share one glyph in the bar and always sit
  in the same section. Clicking the glyph opens a row of its members; ⌘-dragging one member
  brings the rest along; triggers can show or hide a whole group (`showGroup`,
  `hideGroup`), and the palette lists groups.
- Give any item or group its own hot key (Settings › Hot Keys › Items and groups). It opens
  the item's menu the way search does, even when the item is hidden. Clashing combos are
  refused.
- Show downloads in the notch (Transfers, off by default, turned on per profile): a progress
  ring while Safari, Chrome, Firefox, Opera or AirDrop writes into Downloads, a row with
  "Show in Finder" in Expanded, and a "Downloaded" pulse. macOS asks once for access to the
  Downloads folder.
- Replace the macOS volume overlay with a slim bar in the notch (Volume HUD, off by default,
  per profile). The volume keys step by a sixteenth, or finer with ⌥⇧. Without Accessibility
  Somabar only follows the volume and the macOS overlay still shows.
- Show coding agents in the notch. Turn on Settings › Advanced › Listen for coding agents,
  copy `Scripts/somabar-agent-hook.sh` somewhere, and add the hooks from
  `Scripts/claude-code-hooks.example.json` to your Claude Code settings. The notch shows
  when an agent is working, pulses when one needs you or finishes, and lists sessions by
  project with a button that brings the terminal forward. Reports go over
  `~/Library/Application Support/Somabar/agent.sock`, which only your user can reach, one
  JSON line each (`{"session": "…", "project": "…", "state": "working|needsYou|done|ended",
  "detail": "…"}`), or `somabar://agent?session=…&state=…`.
- Answer an agent's permission prompts from the notch (off by default). Turn on Settings ›
  Advanced › Answer permission prompts as well, and keep the example's `PermissionRequest`
  hook (`somabar-agent-hook.sh ask`). The hook sends `{"request": "id", "session": "…",
  "tool": "Bash", "detail": "npm test"}` on the socket and keeps the connection open; the
  agent's row lists the waiting prompt with Allow, Deny and Answer in terminal, the oldest of
  each session first. Somabar writes back one line, `{"id": "…", "decision":
  "allow|deny|ask"}`, and closes; the hook prints Claude Code's decision JSON for allow and
  deny, and nothing otherwise. After 60 s, when the session finishes, when the hook goes away,
  or with the switch off, the answer is "ask" and the agent asks in its terminal as usual.
  Allow works only after a prompt has been up for a second, and is not offered in a profile
  that hides file names. Only the socket can answer: `somabar://` links never do, and
  Somabar never types into a terminal.
- Tint the menu bar (Settings › General › Menu bar style): none, the system accent or a
  colour, at 10–100 %, with an optional 1 px hairline, set apart for light and dark mode. Off
  by default.
- Control calls and music from the notch: mute the microphone during a call (put back when
  the call ends), press the call app's own Leave item where it has one (Zoom, FaceTime,
  Teams, Webex, Slack huddles, Discord; never "End Meeting"), seek with a slider in Music or
  Spotify, and pick the audio output.

Nothing built after the engine alpha has been exercised by hand yet, and the notch has not
been seen on a notched Mac; see `implementation_status.md`.

## Requirements

- macOS 26 (Tahoe). Other versions get the glyph and a message.
- Xcode 26.4 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build the app.
- Accessibility access, to identify and move items. Without it Somabar still hides and
  reveals, but adopts the bar as it is.
- Optional: Screen Recording, only for real item images and icon-change triggers, and
  Automation access to Music or Spotify, only for Now Playing in the notch. Somabar asks
  for each the first time the feature that needs it is used, never before.

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
| `spacing` | `default` | `default`, `snug` (12 pt spacing, 8 pt padding) or `tight` (6 pt, 6 pt) between items. |
| `spacingNoticeShown` | false | Somabar has explained once that a log-out applies spacing everywhere. |
| `notchSurface` | true | Draw the notch surface at all. |
| `drawnNotch` | false | On a display without a notch, draw a 180 × 32 pt one to hang the surface on. |
| `notchGuard` | true | Move Shown items that would sit under the camera housing to Hidden. |
| `realItemImages` | false | Show captured item images in the palette and tray; needs Screen Recording. Off means app icons and titles. |
| `notifyWhenTriggerFires` | false | Show a system notification when a trigger starts holding or switches profile. |
| `displayRules.showEverythingAbovePoints` | 2560 | Keep every item in the bar on a display wider than this; `null` turns it off. |
| `displayRules.trayOnlyOnBuiltInDisplay` | true | Open the tray on the built-in display when there is one. |
| `displayRules.leaveInactiveDisplaysUntouched` | true | Evaluate display rules against the display whose menu bar is active; off means the widest display. |
| `agentSocket` | false | Listen for coding agents on the socket and `somabar://agent`. |
| `agentReplies` | false | Let hooks wait on the socket for Allow or Deny from the notch; only while `agentSocket` is on. |
| `menuBarStyle` | none | Tint colour, strength and hairline for light and dark mode. |

Groups and item hot keys live at the top level of the layout file, beside `profiles`:

```json
"groups": [{"id": "6F1C…", "name": "Dev", "glyph": "hammer",
            "members": [{"bundleID": "com.docker.docker", "title": "", "ordinal": 0}]}],
"itemHotKeys": [
  {"item": {"bundleID": "com.docker.docker", "title": "", "ordinal": 0}, "combo": {…}},
  {"group": "6F1C…", "combo": {…}}
]
```
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

{ "id": "…", "name": "Slack when it has news", "isEnabled": true,
  "condition": {"iconChanged": {"_0": {"bundleID": "com.tinyspeck.slackmacgap", "title": "Item-0", "ordinal": 0}}},
  "action": {"show": {"_0": {"bundleID": "com.tinyspeck.slackmacgap", "title": "Item-0", "ordinal": 0}}} }
```

Conditions: `powerSource` (`battery`, `adapter`), `batteryBelow` (`{"percent": 20}`),
`network` (`ethernet`, `wifi`, `vpn`, `knownRouter`, `unknownNetwork`, `offline`), `display`
(`builtInOnly`, `externalConnected`, `widerThan` with `{"points": 2000}`), `screenSharing`,
`mediaInUse` (`microphone`, `camera`, `either`), `appRunning` and `appFrontmost`
(`{"bundleID": "…"}`), `focus` (`{"name": "Work"}`), `timeOfDay` (minutes since midnight; a
range that ends before it starts crosses midnight), `external` (`{"name": "docker"}`),
`iconChanged` (an item, named like the action's), and `not`, `allOf`, `anyOf` to combine
them. Actions: `show`, `hide`, `switchProfile`.

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
- *Item icon changes* holds for 10 s each time the item's image changes, and another change
  during those seconds starts the 10 s again. Somabar looks at the watched items on its 3 s
  status-window poll, only while an enabled trigger watches them and only with Screen
  Recording, which it asks for once when such a trigger is saved. Declined, the condition
  never holds and Settings shows a note with "Open System Settings".

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
| `App/Notch/Activities` | The live activities: calls, charging, drop to share, Now Playing, Focus, screen share. |
| `App/ItemImages` | ScreenCaptureKit captures for real item images and the icon-change detector. |
| `App/Spacing` | Writes the item spacing defaults and shows the one-time note. |
| `App/Updates` | Sparkle 2 updates and the Updates section in Settings. |
| `App/Groups` | Group glyphs, the group row and hot key targets. |
| `App/MenuBarStyle` | The menu bar tint window. |
| `Scripts` | The coding-agent hook script and a Claude Code hooks example; the release and Sparkle key scripts. |

Your layout lives in `~/Library/Application Support/Somabar/layout.somabar`. Set
`SOMABAR_DOCUMENT_DIR` to run a copy against another directory, for instance to try triggers
on a copy of the file.

## URL scheme

`somabar://toggle`, `somabar://reveal`, `somabar://reveal?tucked`, `somabar://hide`,
`somabar://items`, `somabar://search`, `somabar://tray`, `somabar://settings`,
`somabar://rescan`, `somabar://profile?Focus`, `somabar://timer?25`, `somabar://timer?stop`,
`somabar://set?docker=on`, `somabar://set?docker=off&meeting=on`.

## Updates

Somabar uses Sparkle 2 with EdDSA-signed appcasts. `SUFeedURL` and `SUPublicEDKey` in
Info.plist come from the build settings `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY` in
`Config/Somabar.xcconfig`. The key is empty there, so a build from a plain checkout never
starts the updater: "Check for Updates…" stays disabled with a note and nothing goes online.
The key is set only in the untracked `Config/Release.local.xcconfig`.

## Releasing

`make release` (`Scripts/release.sh`) makes a Release build and writes to `dist/<version>/`:

1. a Release build (universal) into `.build/xcode-release`, with the hardened runtime and
   without `get-task-allow`;
2. Developer ID signing, Sparkle's helpers inside out, then the app, with timestamps;
3. notarization with `xcrun notarytool`, then stapling and a Gatekeeper check;
4. `updates/Somabar-<version>.zip` (what Sparkle downloads) and `Somabar-<version>.dmg`,
   itself signed, notarized and stapled;
5. `updates/appcast.xml` from Sparkle's `generate_appcast`: the published appcast is
   downloaded and extended, the new zip is signed with the EdDSA key, and the signature is
   checked against the key inside the app. A copy goes to `dist/appcast.xml`.

A step without its credentials is skipped with a note, so with nothing configured the script
still produces an ad-hoc-signed zip and dmg to try, with updates off. Real errors stop it. It
refuses to overwrite an existing `dist/<version>` and to publish a build number that is not
newer than the newest one in the appcast: bump `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` in `project.yml` for each release.

One-time setup:

1. `make sparkle-keys` (`Scripts/sparkle-keys.sh --write` to also save it) creates the EdDSA
   key pair, keeps the private key in the login keychain and prints the public key. Put it in
   `Config/Release.local.xcconfig` (copied from the `.example`) as `SPARKLE_PUBLIC_ED_KEY`.
   Back the private key up with `Scripts/sparkle-keys.sh --export <file>`; without it,
   installed copies can never be updated again.
2. Copy `Config/release.local.env.example` to `Config/release.local.env` and set
   `SOMABAR_SIGN_IDENTITY` to your "Developer ID Application: …" identity
   (`security find-identity -v -p codesigning`).
3. Store notary credentials once with
   `xcrun notarytool store-credentials somabar-notary --apple-id <id> --team-id <team>`
   (an app-specific password) and set `SOMABAR_NOTARY_PROFILE=somabar-notary`.

Each release: bump the versions, commit, `make release`, then upload
`updates/Somabar-<version>.zip`, `Somabar-<version>.dmg` and `updates/appcast.xml` to a GitHub
Release tagged `v<version>` (the script prints the `gh release create` line, or runs it with
`SOMABAR_PUBLISH=1`). `SUFeedURL` points at
`https://github.com/anandghegde/somabar/releases/latest/download/appcast.xml`, which always
resolves to the latest release, and each appcast entry points at its own tag's zip. Release
notes: `SOMABAR_RELEASE_NOTES=notes.html` (or `.md`, `.txt`). Every setting is listed at the
top of `Scripts/release.sh`.

The script finds Sparkle's tools in the SwiftPM artifacts under `.build` or DerivedData, or
downloads the release matching the resolved Sparkle version into `.build/sparkle-tools`.

`.github/workflows/release.yml` does the same on a pushed `v*` tag, from repository secrets
(the `.p12`, an App Store Connect API key and the exported Sparkle key) held in a throwaway
keychain and the runner's temporary directory; the header of the workflow lists them.

## Logs

```sh
/usr/bin/log show --last 5m --predicate 'subsystem == "app.somabar"' --info --style compact
```

See `implementation_status.md` for what has been verified on a real bar and what has not.

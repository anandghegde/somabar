#!/usr/bin/env bash
# Builds a Somabar release: Release build, Developer ID signing, notarization and stapling,
# a .zip (what Sparkle downloads) and a .dmg, then an EdDSA-signed appcast.xml.
#
#   make release              # or Scripts/release.sh
#
# Every credential is optional. Without one, its step is skipped with a note, so a checkout
# with nothing configured still produces an ad-hoc-signed build to try. Settings come from the
# environment or from Config/release.local.env (see Config/release.local.env.example):
#
#   SOMABAR_SIGN_IDENTITY     "Developer ID Application: Name (TEAMID)". Unset: ad-hoc signing.
#   SOMABAR_NOTARY_PROFILE    notarytool keychain profile. Unset: no notarization.
#   SOMABAR_NOTARY_KEYCHAIN   keychain holding that profile, if not the login keychain (CI).
#   SPARKLE_PUBLIC_ED_KEY     overrides the key from Config/Release.local.xcconfig.
#   SPARKLE_FEED_URL          overrides the feed from Config/Somabar.xcconfig.
#   SPARKLE_ED_KEY_FILE       private EdDSA key file for generate_appcast. Unset: login keychain.
#   SPARKLE_KEY_ACCOUNT       keychain account of that key (generate_keys --account).
#   SOMABAR_DMG=0             skip the .dmg.
#   SOMABAR_FETCH_APPCAST=0   do not download the published appcast to extend it; use
#                             dist/appcast.xml from the previous run instead.
#   SOMABAR_DOWNLOAD_URL_PREFIX  where the .zip will be downloaded from. Default: the GitHub
#                             release v<version> of the repository in SPARKLE_FEED_URL.
#   SOMABAR_RELEASE_NOTES     .html, .md or .txt file shown by Sparkle for this version.
#   SOMABAR_VERSION / SOMABAR_BUILD  override MARKETING_VERSION / CURRENT_PROJECT_VERSION.
#   SOMABAR_PUBLISH=1         create the GitHub release with gh (only for a notarized build
#                             with an appcast).
#   SOMABAR_DIST_DIR          output folder. Default: dist.
set -euo pipefail

# shellcheck source=Scripts/release-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/release-common.sh"
cd "$ROOT"

load_release_env
require_tools xcodegen xcodebuild ditto plutil codesign

IDENTITY="${SOMABAR_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${SOMABAR_NOTARY_PROFILE:-}"
DIST="${SOMABAR_DIST_DIR:-$ROOT/dist}"
APP="$RELEASE_DERIVED/Build/Products/Release/Somabar.app"
signed=0
notarized=0
appcast_done=0

notary_args() {
    printf '%s\n' --keychain-profile "$NOTARY_PROFILE"
    if [[ -n "${SOMABAR_NOTARY_KEYCHAIN:-}" ]]; then
        printf '%s\n' --keychain "$SOMABAR_NOTARY_KEYCHAIN"
    fi
}

# Submits a file to Apple's notary service and waits. Dies, printing Apple's log, unless accepted.
notarize() {
    local file="$1" result args=() line status id
    while IFS= read -r line; do args+=("$line"); done < <(notary_args)
    result="$(mktemp -t somabar-notary)"
    note "Submitting $(basename "$file") (this usually takes a few minutes)"
    if ! xcrun notarytool submit "$file" "${args[@]}" --wait --output-format json >"$result"; then
        cat "$result" >&2
        die "notarytool could not submit $(basename "$file")"
    fi
    status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
    id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
    rm -f "$result"
    if [[ "$status" != "Accepted" ]]; then
        [[ -n "$id" ]] && xcrun notarytool log "$id" "${args[@]}" >&2 || true
        die "notarization of $(basename "$file") ended as '${status:-unknown}' (submission ${id:-?})"
    fi
    note "Accepted (submission $id)"
}

# Checks an EdDSA signature of a file against a base64 public key, as Sparkle will on the
# user's Mac, independently of which private key generate_appcast used.
verify_ed25519() {
    xcrun swift - "$@" <<'SWIFT'
import CryptoKit
import Foundation

let args = CommandLine.arguments.dropFirst().map { $0 }
guard args.count == 3,
      let file = FileManager.default.contents(atPath: args[0]),
      let signature = Data(base64Encoded: args[1]),
      let keyData = Data(base64Encoded: args[2]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      key.isValidSignature(signature, for: file) else { exit(1) }
SWIFT
}

# ---------------------------------------------------------------------------------------------
step "Generating the Xcode project"
xcodegen generate --quiet

# ---------------------------------------------------------------------------------------------
step "Building Release"
# Xcode adds com.apple.security.get-task-allow (debugging) to any signature unless told not to.
settings=("CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO")
if [[ -n "$IDENTITY" ]]; then
    security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\"" \
        || die "no valid signing identity \"$IDENTITY\" in the keychain (security find-identity -v -p codesigning)"
    team="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$IDENTITY")"
    settings+=("CODE_SIGN_IDENTITY=$IDENTITY" "OTHER_CODE_SIGN_FLAGS=--timestamp")
    [[ -n "$team" ]] && settings+=("DEVELOPMENT_TEAM=$team")
    note "Signing as $IDENTITY"
else
    settings+=("CODE_SIGN_IDENTITY=-")
    note "No SOMABAR_SIGN_IDENTITY: ad-hoc signing (fine to try locally, not to ship)"
fi
[[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]] && settings+=("SPARKLE_PUBLIC_ED_KEY=$SPARKLE_PUBLIC_ED_KEY")
[[ -n "${SPARKLE_FEED_URL:-}" ]] && settings+=("SPARKLE_FEED_URL=$SPARKLE_FEED_URL")
[[ -n "${SOMABAR_VERSION:-}" ]] && settings+=("MARKETING_VERSION=$SOMABAR_VERSION")
[[ -n "${SOMABAR_BUILD:-}" ]] && settings+=("CURRENT_PROJECT_VERSION=$SOMABAR_BUILD")

xcodebuild -project Somabar.xcodeproj -scheme Somabar -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$RELEASE_DERIVED" -quiet \
    "${settings[@]}" clean build
[[ -d "$APP" ]] || die "the build did not produce $APP"

PLIST="$APP/Contents/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw -o - "$PLIST" 2>/dev/null || true)"
FEED_URL="$(plutil -extract SUFeedURL raw -o - "$PLIST" 2>/dev/null || true)"
note "Somabar $VERSION ($BUILD)"
if [[ -n "$PUBLIC_KEY" && -n "$FEED_URL" ]]; then
    note "Updates on: feed $FEED_URL"
else
    warn "this build has no SUPublicEDKey or SUFeedURL, so its updater is off and no appcast is made."
    warn "Run Scripts/sparkle-keys.sh and set SPARKLE_PUBLIC_ED_KEY in Config/Release.local.xcconfig."
fi

# ---------------------------------------------------------------------------------------------
step "Code signing"
if [[ -n "$IDENTITY" ]]; then
    # Xcode signs the framework it embeds but not the helpers inside it; notarization wants every
    # one signed with the Developer ID, the hardened runtime and a timestamp. Inside out, as in
    # Sparkle's documentation.
    sparkle="$APP/Contents/Frameworks/Sparkle.framework"
    sign=(codesign --force --timestamp --options runtime --sign "$IDENTITY")
    for helper in "$sparkle/Versions/B/XPCServices/Installer.xpc" \
        "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
        "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app"; do
        [[ -e "$helper" ]] || die "Sparkle's layout changed: $helper is missing"
        "${sign[@]}" --preserve-metadata=entitlements "$helper"
    done
    "${sign[@]}" "$sparkle"
    "${sign[@]}" --preserve-metadata=entitlements "$APP"
    signed=1
else
    skip "no SOMABAR_SIGN_IDENTITY; keeping Xcode's ad-hoc signature"
fi
codesign --verify --deep --strict "$APP" || die "codesign --verify failed on $APP"
entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
if grep -q "get-task-allow" <<<"$entitlements"; then
    die "the release build carries com.apple.security.get-task-allow; notarization would reject it"
fi
codesign -dv "$APP" 2>&1 | grep -q "flags=.*runtime" || die "the app is not signed with the hardened runtime"
note "Signature verified (hardened runtime, no get-task-allow)"

# ---------------------------------------------------------------------------------------------
step "Notarizing"
if [[ "$signed" == 1 && -n "$NOTARY_PROFILE" ]]; then
    submission="$(mktemp -d -t somabar-notarize)/Somabar.zip"
    ditto -c -k --keepParent "$APP" "$submission"
    notarize "$submission"
    rm -rf "$(dirname "$submission")"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP" || die "Gatekeeper rejects the stapled app"
    notarized=1
elif [[ -n "$NOTARY_PROFILE" ]]; then
    skip "notarization needs Developer ID signing; set SOMABAR_SIGN_IDENTITY"
else
    skip "no SOMABAR_NOTARY_PROFILE (xcrun notarytool store-credentials <profile> ...)"
fi

# ---------------------------------------------------------------------------------------------
step "Packaging"
OUT="$DIST/$VERSION"
UPDATES="$OUT/updates"
ZIP="$UPDATES/Somabar-$VERSION.zip"
DMG="$OUT/Somabar-$VERSION.dmg"
if [[ -e "$OUT" ]]; then
    die "$OUT already exists. Bump MARKETING_VERSION in project.yml, or delete it to rebuild $VERSION."
fi
mkdir -p "$UPDATES"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
note "$ZIP"

if [[ "${SOMABAR_DMG:-1}" == 0 ]]; then
    skip "SOMABAR_DMG=0"
else
    require_tools hdiutil
    staging="$(mktemp -d -t somabar-dmg)"
    ditto "$APP" "$staging/Somabar.app"
    ln -s /Applications "$staging/Applications"
    hdiutil create -quiet -volname "Somabar $VERSION" -srcfolder "$staging" -fs HFS+ \
        -format UDZO -ov "$DMG"
    rm -rf "$staging"
    if [[ "$signed" == 1 ]]; then
        codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    fi
    if [[ "$notarized" == 1 ]]; then
        notarize "$DMG"
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
    fi
    note "$DMG"
fi

# ---------------------------------------------------------------------------------------------
step "Appcast"
if [[ -z "$PUBLIC_KEY" || -z "$FEED_URL" ]]; then
    skip "the build has no Sparkle public key or feed, so no installed copy could verify an update"
else
    SPARKLE_BIN="$(find_sparkle_bin)"
    note "Sparkle tools: $SPARKLE_BIN"

    # Extend the feed that is already out there, so older versions keep their entries.
    previous="$UPDATES/appcast.xml"
    if [[ "${SOMABAR_FETCH_APPCAST:-1}" != 0 ]]; then
        require_tools curl
        code="$(curl -sSL -o "$previous" -w '%{http_code}' "$FEED_URL")" \
            || die "could not download the published appcast from $FEED_URL"
        case "$code" in
            200) note "Extending the published appcast" ;;
            404) rm -f "$previous"; note "No appcast published yet; starting a new one" ;;
            *) die "downloading $FEED_URL returned HTTP $code" ;;
        esac
    elif [[ -f "$DIST/appcast.xml" ]]; then
        cp "$DIST/appcast.xml" "$previous"
        note "Extending dist/appcast.xml (SOMABAR_FETCH_APPCAST=0)"
    else
        note "Starting a new appcast (SOMABAR_FETCH_APPCAST=0 and no dist/appcast.xml)"
    fi
    if [[ -f "$previous" ]]; then
        newest="$(sed -n 's/.*<sparkle:version>\([0-9]*\)<\/sparkle:version>.*/\1/p; s/.*sparkle:version="\([0-9]*\)".*/\1/p' \
            "$previous" | sort -n | tail -1)"
        if [[ -n "$newest" && "$BUILD" =~ ^[0-9]+$ && "$BUILD" -le "$newest" ]]; then
            die "build $BUILD is not newer than build $newest in the appcast. Bump CURRENT_PROJECT_VERSION in project.yml."
        fi
    fi

    if [[ -n "${SOMABAR_RELEASE_NOTES:-}" ]]; then
        [[ -f "$SOMABAR_RELEASE_NOTES" ]] || die "SOMABAR_RELEASE_NOTES: no file at $SOMABAR_RELEASE_NOTES"
        cp "$SOMABAR_RELEASE_NOTES" "$UPDATES/Somabar-$VERSION.${SOMABAR_RELEASE_NOTES##*.}"
    fi

    prefix="${SOMABAR_DOWNLOAD_URL_PREFIX:-}"
    if [[ -z "$prefix" ]]; then
        repo="$(sed -n 's|^https://github.com/\([^/]*/[^/]*\)/releases/.*|\1|p' <<<"$FEED_URL")"
        [[ -n "$repo" ]] || die "the feed is not on GitHub Releases; set SOMABAR_DOWNLOAD_URL_PREFIX"
        prefix="https://github.com/$repo/releases/download/v$VERSION/"
    fi

    appcast_args=(--download-url-prefix "$prefix" --account "${SPARKLE_KEY_ACCOUNT:-ed25519}")
    if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
        [[ -f "$SPARKLE_ED_KEY_FILE" ]] || die "SPARKLE_ED_KEY_FILE: no file at $SPARKLE_ED_KEY_FILE"
        appcast_args+=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
        note "Signing with the key in $SPARKLE_ED_KEY_FILE"
    else
        note "Signing with the key in the login keychain (macOS may ask to allow access)"
    fi
    "$SPARKLE_BIN/generate_appcast" "${appcast_args[@]}" "$UPDATES"

    grep -q "sparkle:edSignature=" "$UPDATES/appcast.xml" || die "appcast.xml has no EdDSA signature"
    grep -qF "Somabar-$VERSION.zip" "$UPDATES/appcast.xml" || die "appcast.xml has no entry for Somabar-$VERSION.zip"
    # The zip's signature must verify against the key the app ships with.
    signature="$(tr -d '\n' <"$UPDATES/appcast.xml" \
        | sed -n "s|.*Somabar-$VERSION.zip\"[^>]*sparkle:edSignature=\"\([^\"]*\)\".*|\1|p")"
    if [[ -z "$signature" ]]; then
        signature="$(tr -d '\n' <"$UPDATES/appcast.xml" \
            | sed -n "s|.*sparkle:edSignature=\"\([^\"]*\)\"[^>]*Somabar-$VERSION.zip\".*|\1|p")"
    fi
    [[ -n "$signature" ]] || die "could not read the signature of Somabar-$VERSION.zip from appcast.xml"
    verify_ed25519 "$ZIP" "$signature" "$PUBLIC_KEY" \
        || die "the appcast signature does not verify against SUPublicEDKey in the app; wrong key?"
    note "The signature verifies against the app's SUPublicEDKey"
    cp "$UPDATES/appcast.xml" "$DIST/appcast.xml"
    appcast_done=1
    note "$UPDATES/appcast.xml"
fi

# ---------------------------------------------------------------------------------------------
step "Publishing"
assets=("$ZIP")
[[ -f "$DMG" ]] && assets+=("$DMG")
[[ -f "$UPDATES/appcast.xml" ]] && assets+=("$UPDATES/appcast.xml")
if [[ "${SOMABAR_PUBLISH:-0}" == 1 ]]; then
    [[ "$notarized" == 1 && "$appcast_done" == 1 ]] \
        || die "SOMABAR_PUBLISH=1 needs a notarized build and an appcast; see the skipped steps above"
    require_tools gh git
    [[ -z "$(git status --porcelain)" ]] || warn "the working tree has uncommitted changes"
    gh release create "v$VERSION" "${assets[@]}" --title "Somabar $VERSION" \
        --target "$(git rev-parse HEAD)" --generate-notes
else
    skip "not publishing (SOMABAR_PUBLISH=1 does it with gh). By hand:"
    printf '      gh release create v%s' "$VERSION"
    printf ' %q' "${assets[@]}"
    printf ' --title "Somabar %s" --generate-notes\n' "$VERSION"
fi

step "Done: Somabar $VERSION ($BUILD)"
note "signed with Developer ID: $([[ $signed == 1 ]] && echo yes || echo 'no (ad-hoc)')"
note "notarized and stapled:    $([[ $notarized == 1 ]] && echo yes || echo no)"
note "appcast:                  $([[ $appcast_done == 1 ]] && echo yes || echo no)"
note "output:                   $OUT"

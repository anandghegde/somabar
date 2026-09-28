# shellcheck shell=bash
# Helpers shared by Scripts/release.sh and Scripts/sparkle-keys.sh. Sourced, not run.
# Written for the bash 3.2 that ships with macOS.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBUG_DERIVED="$ROOT/.build/xcode"
RELEASE_DERIVED="$ROOT/.build/xcode-release"
SPARKLE_TOOLS_CACHE="$ROOT/.build/sparkle-tools"
# Only used when no resolved package or project says otherwise.
SPARKLE_FALLBACK_VERSION="2.10.0"

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
skip() { printf '    skipped: %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_tools() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not installed or not on PATH"
    done
}

# Sources Config/release.local.env when present. Variables already set in the environment win.
load_release_env() {
    local file="$ROOT/Config/release.local.env" name kept
    local names="SOMABAR_SIGN_IDENTITY SOMABAR_NOTARY_PROFILE SOMABAR_NOTARY_KEYCHAIN SOMABAR_DMG
        SOMABAR_DIST_DIR SOMABAR_FETCH_APPCAST SOMABAR_DOWNLOAD_URL_PREFIX SOMABAR_RELEASE_NOTES
        SOMABAR_PUBLISH SOMABAR_VERSION SOMABAR_BUILD SPARKLE_ED_KEY_FILE SPARKLE_KEY_ACCOUNT
        SPARKLE_PUBLIC_ED_KEY SPARKLE_FEED_URL SPARKLE_BIN"
    [[ -f "$file" ]] || return 0
    for name in $names; do
        if [[ -n "${!name:-}" ]]; then printf -v "kept_$name" '%s' "${!name}"; fi
    done
    # shellcheck source=/dev/null
    source "$file"
    for name in $names; do
        kept="kept_$name"
        if [[ -n "${!kept:-}" ]]; then printf -v "$name" '%s' "${!kept}"; fi
    done
    note "Loaded Config/release.local.env"
}

# The Sparkle version the Xcode project resolved, else the fallback.
sparkle_version() {
    local resolved="$ROOT/Somabar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    local version=""
    if [[ -f "$resolved" ]]; then
        version="$(awk '/"identity" *: *"sparkle"/ { found = 1 }
            found && /"version"/ { gsub(/[^0-9.]/, "", $3); print $3; exit }' "$resolved")"
    fi
    printf '%s\n' "${version:-$SPARKLE_FALLBACK_VERSION}"
}

# Prints the directory holding Sparkle's command line tools (generate_appcast, generate_keys,
# sign_update). Looks at $SPARKLE_BIN, then the SwiftPM artifacts of the release and debug
# builds, then Xcode's DerivedData, then downloads the release matching the resolved version.
find_sparkle_bin() {
    local candidate version archive url
    local suffix="SourcePackages/artifacts/sparkle/Sparkle/bin"
    for candidate in "${SPARKLE_BIN:-}" "$RELEASE_DERIVED/$suffix" "$DEBUG_DERIVED/$suffix" \
        "$HOME"/Library/Developer/Xcode/DerivedData/Somabar-*/"$suffix"; do
        if [[ -n "$candidate" && -x "$candidate/generate_appcast" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    version="$(sparkle_version)"
    candidate="$SPARKLE_TOOLS_CACHE/$version/bin"
    if [[ ! -x "$candidate/generate_appcast" ]]; then
        require_tools curl tar
        url="https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz"
        archive="$SPARKLE_TOOLS_CACHE/Sparkle-$version.tar.xz"
        mkdir -p "$SPARKLE_TOOLS_CACHE/$version"
        printf '    Downloading Sparkle %s tools from %s\n' "$version" "$url" >&2
        curl -fsSL -o "$archive" "$url" || die "could not download $url"
        tar -xJf "$archive" -C "$SPARKLE_TOOLS_CACHE/$version" || die "could not unpack $archive"
        rm -f "$archive"
        # Keep only the tools.
        find "$SPARKLE_TOOLS_CACHE/$version" -mindepth 1 -maxdepth 1 ! -name bin -exec rm -rf {} +
    fi
    [[ -x "$candidate/generate_appcast" ]] || die "Sparkle's tools are not in $candidate"
    printf '%s\n' "$candidate"
}

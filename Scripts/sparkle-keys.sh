#!/usr/bin/env bash
# One-time Sparkle key setup, wrapping Sparkle's generate_keys.
#
#   Scripts/sparkle-keys.sh              create the EdDSA key pair (or find the existing one),
#                                        print the public key and the xcconfig line for it
#   Scripts/sparkle-keys.sh --write      also set it in Config/Release.local.xcconfig
#   Scripts/sparkle-keys.sh --print      only print the public key of the existing pair
#   Scripts/sparkle-keys.sh --export F   write the private key to file F (for a CI secret or
#                                        another Mac; import there with generate_keys -f F)
#
# The private key lives in the login keychain as "Private key for signing Sparkle updates";
# macOS may ask to allow access. Back it up: losing it means installed copies can never be
# updated again. It never goes into this repository. Set SPARKLE_KEY_ACCOUNT to use a keychain
# account other than Sparkle's default (ed25519); Scripts/release.sh reads the same variable.
set -euo pipefail

# shellcheck source=Scripts/release-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/release-common.sh"
cd "$ROOT"

mode="${1:-create}"
account=(--account "${SPARKLE_KEY_ACCOUNT:-ed25519}")
local_xcconfig="$ROOT/Config/Release.local.xcconfig"

SPARKLE_BIN="$(find_sparkle_bin)"
generate_keys="$SPARKLE_BIN/generate_keys"

public_key() {
    local key
    key="$("$generate_keys" "${account[@]}" -p | tail -1 | tr -d '[:space:]')"
    [[ -n "$key" ]] || die "generate_keys printed no public key"
    printf '%s\n' "$key"
}

write_xcconfig() {
    local key="$1"
    if [[ ! -f "$local_xcconfig" ]]; then
        cp "$ROOT/Config/Release.local.xcconfig.example" "$local_xcconfig"
    fi
    if grep -q '^SPARKLE_PUBLIC_ED_KEY *=' "$local_xcconfig"; then
        sed -i '' "s|^SPARKLE_PUBLIC_ED_KEY *=.*|SPARKLE_PUBLIC_ED_KEY = $key|" "$local_xcconfig"
    else
        printf 'SPARKLE_PUBLIC_ED_KEY = %s\n' "$key" >>"$local_xcconfig"
    fi
    note "Wrote the key to Config/Release.local.xcconfig (ignored by git)"
}

case "$mode" in
    create | --write)
        step "Creating or finding the Sparkle signing key in the login keychain"
        "$generate_keys" "${account[@]}"
        key="$(public_key)"
        step "Public key"
        note "$key"
        if [[ "$mode" == --write ]]; then
            write_xcconfig "$key"
        else
            note "Put this line in Config/Release.local.xcconfig (or rerun with --write):"
            note "SPARKLE_PUBLIC_ED_KEY = $key"
        fi
        note "Back up the private key: Scripts/sparkle-keys.sh --export <file>, kept somewhere safe."
        ;;
    --print)
        public_key
        ;;
    --export)
        file="${2:-}"
        [[ -n "$file" ]] || die "usage: $0 --export <file>"
        [[ ! -e "$file" ]] || die "$file already exists"
        (umask 077 && "$generate_keys" "${account[@]}" -x "$file")
        note "Exported the private key to $file. Treat it like a password; delete it once stored."
        ;;
    -h | --help)
        sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "unknown option '$mode' (try --help)"
        ;;
esac

#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Setup Self-Signed Code Signing Certificate for OkBrainMacOSAgent
# ---------------------------------------------------------------------------
# This creates a persistent local certificate so macOS remembers Screen
# Recording and Accessibility permissions across rebuilds.
#
# Run this once, then rebuild your app. After that, permissions stick.
# ---------------------------------------------------------------------------

CERT_NAME="OkBrain Dev"
KEYCHAIN="$HOME/Library/Keychains/okbrain.keychain-db"
KEYCHAIN_PASS="okbrain"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_PEM="$(mktemp /tmp/okbrain_cert.XXXXXX.pem)"
KEY_PEM="$(mktemp /tmp/okbrain_key.XXXXXX.pem)"
P12_FILE="$(mktemp /tmp/okbrain.XXXXXX.p12)"

cleanup() {
    rm -f "$CERT_PEM" "$KEY_PEM" "$P12_FILE"
}
trap cleanup EXIT

find_okbrain_identity() {
    security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | awk -v name="$CERT_NAME" '
        $2 ~ /^[[:xdigit:]]{40}$/ && index($0, "\"" name "\"") { print $2; exit }
    '
}

add_keychain_to_search_list() {
    local keychain
    local found="false"
    local existing=()

    while IFS= read -r keychain; do
        [ -n "$keychain" ] || continue
        existing+=("$keychain")
        if [ "$keychain" = "$KEYCHAIN" ]; then
            found="true"
        fi
    done < <(security list-keychains -d user 2>/dev/null | sed -e 's/^[[:space:]]*"//' -e 's/"$//')

    if [ "${#existing[@]}" -eq 0 ]; then
        existing=("$HOME/Library/Keychains/login.keychain-db")
    fi

    if [ "$found" = "false" ]; then
        security list-keychains -d user -s "${existing[@]}" "$KEYCHAIN"
    fi
}

delete_stale_certificates() {
    while security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; do
        security delete-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1 || break
    done
}

trust_certificate() {
    echo "→ Trusting certificate for code signing..."
    security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT_PEM" 2>/dev/null || \
        sudo security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT_PEM"
}

allow_codesign_access() {
    echo "→ Allowing codesign to access the keychain..."
    security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true
}

create_identity() {
    if ! command -v openssl >/dev/null 2>&1; then
        echo "❌  openssl is required to create the code-signing identity."
        exit 1
    fi

    echo "→ Creating self-signed certificate '$CERT_NAME' with openssl..."

    openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_PEM" \
        -out "$CERT_PEM" \
        -days 3650 -nodes \
        -subj "/CN=$CERT_NAME" \
        -addext "basicConstraints = critical, CA:TRUE" \
        -addext "keyUsage = critical, digitalSignature, keyCertSign" \
        -addext "extendedKeyUsage = codeSigning" >/dev/null 2>&1

    openssl pkcs12 -export \
        -out "$P12_FILE" \
        -inkey "$KEY_PEM" \
        -in "$CERT_PEM" \
        -name "$CERT_NAME" \
        -passout pass:"$KEYCHAIN_PASS" >/dev/null 2>&1

    security import "$P12_FILE" \
        -f pkcs12 \
        -k "$KEYCHAIN" \
        -P "$KEYCHAIN_PASS" \
        -T /usr/bin/codesign >/dev/null
}

echo "🔐  OkBrain Code Signing Setup"
echo ""

# 1. Create a dedicated keychain (keeps things tidy)
if [ ! -f "$KEYCHAIN" ]; then
    echo "→ Creating keychain: okbrain.keychain-db"
    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security set-keychain-settings -t 3600 -u "$KEYCHAIN"
else
    echo "→ Keychain already exists, unlocking"
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
fi

# 2. Add keychain to search list without clobbering the user's existing list.
add_keychain_to_search_list

# 3. Reuse an existing valid identity when possible so permissions stay stable.
identity="$(find_okbrain_identity || true)"
if [ -n "$identity" ]; then
    echo "→ Reusing existing signing identity '$CERT_NAME' ($identity)"
    security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN" >"$CERT_PEM" 2>/dev/null || true
else
    echo "→ No valid signing identity found; removing stale '$CERT_NAME' certificates"
    delete_stale_certificates
    create_identity
fi

# 4. Trust the certificate and allow non-interactive codesign access.
if [ -s "$CERT_PEM" ]; then
    trust_certificate
fi
allow_codesign_access

# 5. Verify
echo ""
echo "→ Verifying signing identity..."
identity="$(find_okbrain_identity || true)"
if [ -n "$identity" ]; then
    echo ""
    echo "✅  SUCCESS! Certificate '$CERT_NAME' is ready."
    echo "   Identity: $identity"
    echo ""
    echo "   Next steps:"
    echo "   1. Run: $SCRIPT_DIR/build.sh"
    echo "   2. Launch the app from dist/OkBrainMacOSAgent.app"
    echo "   3. Grant Screen Recording & Accessibility permissions ONCE"
    echo "   4. From now on, rebuilds will keep the same permissions 🎉"
    echo ""
else
    echo ""
    echo "❌  Certificate setup finished, but codesign still cannot see '$CERT_NAME'."
    echo "   Try: security find-identity -v -p codesigning '$KEYCHAIN'"
    echo "   If it is empty, open Keychain Access and manually trust the cert."
    exit 1
fi

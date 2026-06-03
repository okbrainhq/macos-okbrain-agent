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
CERT_PEM="/tmp/okbrain_cert.pem"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# 2. Add keychain to search list
security list-keychains -s "$HOME/Library/Keychains/login.keychain-db" "$KEYCHAIN"

# 3. Create self-signed certificate using certtool (automated via expect)
#    If expect automation fails, the script prints manual instructions.

if ! command -v expect &>/dev/null; then
    echo "❌  'expect' is not installed. Please install it first:"
    echo "    brew install expect"
    exit 1
fi

echo "→ Creating self-signed certificate '$CERT_NAME' via certtool..."
echo "   (this will take ~10 seconds)"
echo ""

# Ensure keychain is unlocked before certtool (certtool rejects p= on existing keychains)
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" 2>/dev/null || true

set +e
expect <<EXPECT_SCRIPT
set timeout 30
spawn certtool c k="$KEYCHAIN" o="$CERT_PEM" v

expect {
    "Enter certificate name:" {
        send "$CERT_NAME\r"
        exp_continue
    }
    "Is this a self-signed certificate?" {
        send "y\r"
        exp_continue
    }
    "Enter a password for the private key:" {
        send "\r"
        exp_continue
    }
    "Enter password again:" {
        send "\r"
        exp_continue
    }
    "Enter key size in bits:" {
        send "\r"
        exp_continue
    }
    -re "(?i)password.*keychain|keychain.*password|enter password|enter passphrase|unlock keychain" {
        send "$KEYCHAIN_PASS\r"
        exp_continue
    }
    -re "Enter .*:" {
        send "\r"
        exp_continue
    }
    "Key usage" {
        send "\r"
        exp_continue
    }
    "Extended key usage" {
        send "\r"
        exp_continue
    }
    timeout {
        puts "\n⚠️  EXPECT TIMEOUT — certtool may be stuck on an unrecognized prompt"
        exit 1
    }
    eof
}
EXPECT_SCRIPT
CERTTOOL_STATUS=$?
set -e

if [ $CERTTOOL_STATUS -ne 0 ] || [ ! -f "$CERT_PEM" ]; then
    echo ""
    echo "⚠️  certtool failed — trying openssl fallback..."
    echo ""

    # Fallback: create cert with openssl and import as PKCS#12
    openssl req -x509 -newkey rsa:2048 \
        -keyout /tmp/okbrain_key.pem \
        -out "$CERT_PEM" \
        -days 3650 -nodes \
        -subj "/CN=$CERT_NAME" \
        -addext "keyUsage = critical, digitalSignature" \
        -addext "extendedKeyUsage = codeSigning" 2>/dev/null

    openssl pkcs12 -export \
        -out /tmp/okbrain.p12 \
        -inkey /tmp/okbrain_key.pem \
        -in "$CERT_PEM" \
        -name "$CERT_NAME" \
        -passout pass:"$KEYCHAIN_PASS" 2>/dev/null

    security import /tmp/okbrain.p12 \
        -k "$KEYCHAIN" \
        -P "$KEYCHAIN_PASS" \
        -T /usr/bin/codesign 2>/dev/null

    if [ $? -ne 0 ]; then
        echo "❌  openssl fallback also failed."
        echo ""
        echo "   Manual fallback:"
        echo "   1. Open Keychain Access (Cmd+Space → 'Keychain Access')"
        echo "   2. Keychain Access menu → Certificate Assistant → Create a Certificate..."
        echo "   3. Name: $CERT_NAME"
        echo "   4. Identity Type: Self Signed Root"
        echo "   5. Certificate Type: Code Signing"
        echo "   6. Check 'Let me override defaults' → Continue → Continue..."
        echo "   7. Save it to the 'okbrain' keychain"
        echo ""
        echo "   Then run this script again."
        exit 1
    fi
fi

# 4. Trust the certificate for code signing
echo ""
echo "→ Trusting certificate for code signing..."
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT_PEM" 2>/dev/null || \
    security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT_PEM" 2>/dev/null || true

# 5. Allow codesign to access the keychain
echo "→ Allowing codesign to access the keychain..."
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$KEYCHAIN_PASS" "$KEYCHAIN" 2>/dev/null || true

# 6. Verify
echo ""
echo "→ Verifying signing identity..."
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo ""
    echo "✅  SUCCESS! Certificate '$CERT_NAME' is ready."
    echo ""
    echo "   Next steps:"
    echo "   1. Run: $SCRIPT_DIR/build.sh"
    echo "   2. Launch the app from dist/OkBrainMacOSAgent.app"
    echo "   3. Grant Screen Recording & Accessibility permissions ONCE"
    echo "   4. From now on, rebuilds will keep the same permissions 🎉"
    echo ""
else
    echo ""
    echo "⚠️  Certificate created but codesign cannot see it yet."
    echo "   Try: security find-identity -v -p codesigning"
    echo "   If empty, open Keychain Access and manually trust the cert."
    exit 1
fi

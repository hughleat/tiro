#!/bin/zsh
set -euo pipefail
umask 077

IDENTITY="${TIRO_LOCAL_SIGNING_IDENTITY:-Tiro Local Development}"
KEYCHAIN="${TIRO_LOCAL_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

[[ -f "$KEYCHAIN" ]] || {
    print -u2 "error: login keychain not found: $KEYCHAIN"
    exit 1
}

work="$(mktemp -d "${TMPDIR%/}/tiro-signing.XXXXXX")"
cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

if ! identities="$(security find-identity -v -p codesigning "$KEYCHAIN" 2>&1)"; then
    print -u2 "error: cannot read the signing keychain: $KEYCHAIN"
    exit 1
fi

identity_matches="$(print -r -- "$identities" | grep -F -- "\"$IDENTITY\"" || true)"
if [[ -n "$identity_matches" ]]; then
    identity_count="$(print -r -- "$identity_matches" | wc -l | tr -d ' ')"
    [[ "$identity_count" == "1" ]] || {
        print -u2 "error: multiple Tiro signing identities are installed; remove the duplicates in Keychain Access"
        exit 1
    }
    fingerprint="$(print -r -- "$identity_matches" | awk '{print $2}')"
    cp /usr/bin/true "$work/signing-test"
    if ! codesign --force --keychain "$KEYCHAIN" --sign "$fingerprint" "$work/signing-test" >/dev/null 2>&1 \
        || ! codesign --verify --strict "$work/signing-test"; then
        print -u2 "error: the Tiro identity is installed but unavailable; unlock the login keychain"
        exit 1
    fi
    print "Local signing identity already exists and works: $IDENTITY"
    exit 0
fi

# A cancelled import can leave an unusable certificate. Remove that exact
# fingerprint, its associated private key, and its trust setting before repair.
existing_fingerprints="$(security find-certificate -a -c "$IDENTITY" -Z "$KEYCHAIN" 2>/dev/null \
    | awk -v label="\"labl\"<blob>=\"$IDENTITY\"" '
        /^SHA-1 hash:/ { fingerprint = $3 }
        index($0, label) { print fingerprint }
    ' || true)"
while IFS= read -r existing_fingerprint; do
    [[ -n "$existing_fingerprint" ]] || continue
    security delete-identity -Z "$existing_fingerprint" -t "$KEYCHAIN" >/dev/null 2>&1 \
        || security delete-certificate -Z "$existing_fingerprint" -t "$KEYCHAIN"
done <<< "$existing_fingerprints"

cat > "$work/certificate.conf" <<EOF
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no

[subject]
CN = $IDENTITY
O = Tiro

[extensions]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

password="$(openssl rand -hex 24)"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -config "$work/certificate.conf" \
    -keyout "$work/private-key.pem" \
    -out "$work/certificate.pem" >/dev/null 2>&1
openssl pkcs12 -export \
    -inkey "$work/private-key.pem" \
    -in "$work/certificate.pem" \
    -name "$IDENTITY" \
    -passout "pass:$password" \
    -out "$work/identity.p12"
fingerprint="$(openssl x509 -in "$work/certificate.pem" -sha1 -fingerprint -noout | cut -d= -f2 | tr -d :)"

rollback() {
    security remove-trusted-cert "$work/certificate.pem" >/dev/null 2>&1 || true
    security delete-identity -Z "$fingerprint" -t "$KEYCHAIN" >/dev/null 2>&1 \
        || security delete-certificate -Z "$fingerprint" -t "$KEYCHAIN" >/dev/null 2>&1 \
        || true
}

if ! security import "$work/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$password" \
    -x \
    -T /usr/bin/codesign >/dev/null; then
    rollback
    print -u2 "error: unlock the login keychain in Keychain Access, then run this script again"
    exit 1
fi

if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$work/certificate.pem"; then
    rollback
    print -u2 "error: macOS did not authorize code-signing trust for the Tiro certificate"
    exit 1
fi

if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -F -- "$fingerprint" >/dev/null; then
    rollback
    print -u2 "error: the imported certificate is not available for code signing"
    exit 1
fi

cp /usr/bin/true "$work/signing-test"
if ! codesign --force --keychain "$KEYCHAIN" --sign "$fingerprint" "$work/signing-test" >/dev/null 2>&1 \
    || ! codesign --verify --strict "$work/signing-test"; then
    rollback
    print -u2 "error: the imported identity could not sign a test executable"
    exit 1
fi

print "Created local signing identity: $IDENTITY"

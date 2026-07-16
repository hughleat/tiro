#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tiro-permissions-test.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

HARNESS="$TEMP_ROOT/main.swift"
apply_harness() {
    printf '%s\n' \
        'import Foundation' \
        '' \
        'let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)' \
        'let nested = root.appendingPathComponent("nested", isDirectory: true)' \
        'let existing = nested.appendingPathComponent("existing.txt")' \
        'try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)' \
        'try Data("existing".utf8).write(to: existing)' \
        'try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)' \
        'try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nested.path)' \
        'try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: existing.path)' \
        'try PrivateFilePermissions.repairTree(at: root)' \
        'try PrivateFilePermissions.write(Data("new".utf8), to: root.appendingPathComponent("new.txt"))' \
        'do {' \
        '    try PrivateFilePermissions.ensureFile(at: root.appendingPathComponent("linked.txt"))' \
        '    fatalError("expected symlink file to be rejected")' \
        '} catch {}' \
        > "$HARNESS"
}

apply_harness
swiftc \
    -module-cache-path "$TEMP_ROOT/module-cache" \
    "$ROOT/Sources/Tiro/PrivateFilePermissions.swift" \
    "$HARNESS" \
    -o "$TEMP_ROOT/permissions-harness"

PRIVATE_ROOT="$TEMP_ROOT/private"
OUTSIDE="$TEMP_ROOT/outside.txt"
mkdir -p "$PRIVATE_ROOT"
print -n 'outside' > "$OUTSIDE"
chmod 0644 "$OUTSIDE"
ln -s "$OUTSIDE" "$PRIVATE_ROOT/linked.txt"

"$TEMP_ROOT/permissions-harness" "$PRIVATE_ROOT"

[[ "$(stat -f '%Lp' "$PRIVATE_ROOT")" == 700 ]]
[[ "$(stat -f '%Lp' "$PRIVATE_ROOT/nested")" == 700 ]]
[[ "$(stat -f '%Lp' "$PRIVATE_ROOT/nested/existing.txt")" == 600 ]]
[[ "$(stat -f '%Lp' "$PRIVATE_ROOT/new.txt")" == 600 ]]
[[ "$(stat -f '%Lp' "$OUTSIDE")" == 644 ]]
[[ -L "$PRIVATE_ROOT/linked.txt" ]]

print "Private file permission assertions passed"

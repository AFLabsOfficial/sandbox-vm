#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: make-seed.sh <output.iso> <pubkey-file>..."
  echo "Creates a seed ISO with the given SSH public keys."
  exit 1
}

[ "${1:-}" ] || usage
[ "${2:-}" ] || usage

OUTPUT="$1"
shift

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

: > "$TMPDIR/authorized_keys"
for PUBKEY_FILE in "$@"; do
  if [ ! -f "$PUBKEY_FILE" ]; then
    echo "error: public key file not found: $PUBKEY_FILE"
    exit 1
  fi
  cat "$PUBKEY_FILE" >> "$TMPDIR/authorized_keys"
done

if command -v mkisofs >/dev/null 2>&1; then
  ISO_CMD="mkisofs"
elif command -v genisoimage >/dev/null 2>&1; then
  ISO_CMD="genisoimage"
else
  echo "error: mkisofs or genisoimage required"
  echo "  linux:  sudo apt install genisoimage"
  echo "  macos:  brew install cdrtools"
  echo "  nix:    nix shell nixpkgs#cdrtools"
  exit 1
fi

"$ISO_CMD" -quiet -V SEEDCONFIG -J -R -o "$OUTPUT" "$TMPDIR"

echo "seed ISO created: $OUTPUT"

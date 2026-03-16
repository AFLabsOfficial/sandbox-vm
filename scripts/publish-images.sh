#!/usr/bin/env bash
set -euo pipefail

# move images from ~/inc to ~/http/iso
#
# layout:
#   ~/http/iso/
#   ├── sandbox-headless-x86_64-e3b6344-20260306.abc1234.qcow2
#   ├── sandbox-headless-x86_64-e3b6344-20260306.abc1234.sha256
#   └── ...

INC_DIR="${HOME}/inc"
ISO_DIR="${HOME}/http/iso"

mkdir -p "$ISO_DIR"

# move new images and their hashes
moved=0
for img in "$INC_DIR"/sandbox-headless-*.qcow2 "$INC_DIR"/sandbox-gui-*.qcow2; do
  [ -f "$img" ] || continue
  mv "$img" "$ISO_DIR/"
  hash="${img%.qcow2}.sha256"
  [ -f "$hash" ] && mv "$hash" "$ISO_DIR/"
  moved=$((moved + 1))
done

echo "moved $moved new image(s)"

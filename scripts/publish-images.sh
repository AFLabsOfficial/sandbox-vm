#!/usr/bin/env bash
set -euo pipefail

# move images from ~/inc to ~/http/iso
#
# layout:
#   ~/http/iso/
#   ├── sandbox-headless-x86_64-v0.1.0-20260306.abc1234.qcow2
#   ├── sandbox-headless-x86_64-v0.1.0-20260306.abc1234.sha256
#   ├── sandbox-headless-x86_64-v0.1.0-20260306.abc1234.sha256.asc
#   └── ...

main() {
	local inc_dir="${HOME}/inc"
	local iso_dir="${HOME}/http/iso"

	mkdir -p "$iso_dir"

	local moved=0 img hash sig
	for img in "$inc_dir"/sandbox-headless-*.qcow2 "$inc_dir"/sandbox-gui-*.qcow2; do
		[ -f "$img" ] || continue
		mv "$img" "$iso_dir/"
		hash="${img%.qcow2}.sha256"
		[ -f "$hash" ] && mv "$hash" "$iso_dir/"
		sig="${hash}.asc"
		[ -f "$sig" ] && mv "$sig" "$iso_dir/"
		moved=$((moved + 1))
	done

	echo "moved $moved new image(s)"
}

main "$@"

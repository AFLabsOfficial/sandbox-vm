#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
setup_colors

usage() {
	echo "Usage: sign.sh <image.qcow2>..."
	exit "${1:-0}"
}

sign_image() {
	local image="$1"
	[ -f "$image" ] || die "file not found: $image"

	local name base dir hash
	name="$(basename "$image")"
	base="${name%.qcow2}"
	dir="$(dirname "$image")"
	hash=$(sha256_file "$image")

	echo "${bold}signing:${reset} $image" >&2
	echo "${bold}sha256:${reset} $hash" >&2
	echo "$hash  $name" >"$dir/$base.sha256"
	gpg --detach-sign --armor "$dir/$base.sha256"
}

main() {
	case "${1:-}" in
	-h | --help) usage ;;
	"") usage 1 ;;
	esac

	require_cmd gpg

	for image in "$@"; do
		sign_image "$image"
	done
}

main "$@"

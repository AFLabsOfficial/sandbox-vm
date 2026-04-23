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
	[ "${image%.qcow2}" != "$image" ] || die "expected a .qcow2 file, got: $image"
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
	local -a images=()
	while [ $# -gt 0 ]; do
		case "$1" in
		-h | --help) usage ;;
		-*) die_usage "unknown option: $1" ;;
		*)
			images+=("$1")
			shift
			;;
		esac
	done

	[ "${#images[@]}" -gt 0 ] || usage 1

	require_cmd gpg

	for image in "${images[@]}"; do
		sign_image "$image"
	done
}

main "$@"

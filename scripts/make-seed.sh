#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
setup_colors

WORK_DIR=""
cleanup() {
	[ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
	return 0
}
trap cleanup EXIT

usage() {
	echo "Usage: make-seed.sh <output.iso> <pubkey-file>..."
	echo "Creates a seed ISO with the given SSH public keys."
	exit "${1:-0}"
}

main() {
	case "${1:-}" in
	-h | --help) usage ;;
	"") usage 1 ;;
	esac
	[ "${2:-}" ] || usage 1

	local output="$1"
	shift

	WORK_DIR=$(mktemp -d)

	: >"$WORK_DIR/authorized_keys"
	local pubkey_file
	for pubkey_file in "$@"; do
		[ -f "$pubkey_file" ] || die "public key file not found: $pubkey_file"
		cat "$pubkey_file" >>"$WORK_DIR/authorized_keys"
	done

	local iso_cmd=""
	if command -v mkisofs &>/dev/null; then
		iso_cmd="mkisofs"
	elif command -v genisoimage &>/dev/null; then
		iso_cmd="genisoimage"
	else
		die "mkisofs or genisoimage required (linux: apt install genisoimage, macos: brew install cdrtools, nix: nix shell nixpkgs#cdrtools)"
	fi

	"$iso_cmd" -quiet -V SEEDCONFIG -J -R -o "$output" "$WORK_DIR"
	info "seed ISO created: $output"
}

main "$@"

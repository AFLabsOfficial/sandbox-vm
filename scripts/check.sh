#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
setup_colors

# verify a tagged build would get off the ground, without paying for a full
# image build: instantiate both image derivations and build the packaged tools
#
# NOTE:(@janezicmatej) `nix flake check` is deliberately not used. it cannot run
# with --no-build here (stylix reads base16-schemes through import-from-
# derivation, so evaluation itself needs a realised drv), it evaluates the darwin
# outputs ci never builds, and doing every output in one process peaks well over
# 3G and gets oom killed

usage() {
	cat <<EOF
Usage: check.sh [options]

Instantiate the sandbox image derivations and build the packaged tools. Fails on
anything a bump can break at evaluation time: renamed nixpkgs options, nixos
assertions, home-manager changes, bad source hashes.

Options:
  --arch <arch>      Architecture to check (default: host)
  -h, --help         Show usage
EOF
	exit "${1:-0}"
}

main() {
	local arch=""

	while [ $# -gt 0 ]; do
		case "$1" in
		--arch)
			arch="$2"
			shift 2
			;;
		-h | --help) usage ;;
		*) die_usage "unknown option: $1" ;;
		esac
	done

	require_cmd nix
	arch=$(normalize_arch "$arch")

	cd "$REPO_DIR"

	# instantiating an image forces system.build.toplevel, so the whole nixos
	# and home-manager evaluation is covered here. one nix process per attribute:
	# evaluating all of them in a single process needs upwards of 3G
	local variant drv
	for variant in headless gui; do
		info "instantiating sandbox-$variant ($arch)"
		drv=$(nix eval --raw ".#packages.${arch}-linux.sandbox-${variant}.drvPath")
		echo "$drv"
	done

	# the images embed these, but building them separately is what actually
	# validates the hashes a bump commit wrote, plus the install and fixup phases
	local host_arch
	host_arch=$(normalize_arch "")
	if [ "$arch" != "$host_arch" ]; then
		warn "skipping tool builds: $arch cannot be built on a $host_arch host"
		return 0
	fi

	info "building packaged tools ($arch)"
	nix build --no-link --print-out-paths \
		".#packages.${arch}-linux.claude-code" \
		".#packages.${arch}-linux.codex" \
		".#packages.${arch}-linux.pi"
}

main "$@"

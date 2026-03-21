#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
setup_colors

usage() {
	cat <<EOF
Usage: build.sh [options]

Options:
  --headless         Build headless variant
  --gui              Build GUI variant
  --arch <arch>      Target architecture (default: host)
  --docker           Build using Docker instead of nix (Linux only, requires KVM)
  -s, --sign         Sign the image after building
  -h, --help         Show usage
EOF
	exit "${1:-0}"
}

main() {
	local arch="" variant="" docker=false sign=false

	while [ $# -gt 0 ]; do
		case "$1" in
		--headless)
			variant="headless"
			shift
			;;
		--gui)
			variant="gui"
			shift
			;;
		--arch)
			arch="$2"
			shift 2
			;;
		--docker)
			docker=true
			shift
			;;
		-s | --sign)
			sign=true
			shift
			;;
		-h | --help) usage ;;
		*)
			echo "${red}error:${reset} unknown option: $1" >&2
			usage 1
			;;
		esac
	done

	[ -n "$variant" ] || die "specify --headless or --gui"
	arch=$(normalize_arch "$arch")

	local package="packages.${arch}-linux.sandbox-${variant}"

	# preflight checks
	if [ "$sign" = true ]; then
		require_cmd gpg "--sign requires gpg"
	fi

	if [ "$docker" = true ]; then
		require_cmd docker
		[ "$(uname -s)" = "Linux" ] || die "--docker requires Linux (KVM is not available inside Docker on macOS)"
		[ -e /dev/kvm ] || die "/dev/kvm not found, KVM is required for image builds"

		local host_arch
		host_arch="$(uname -m)"
		[ "$arch" = "$host_arch" ] || die "--docker cannot cross-build (host is $host_arch, target is $arch), use nix with a remote builder"
	else
		require_cmd nix "use --docker to build without nix"
	fi

	mkdir -p "$REPO_DIR/dist"

	if [ "$docker" = true ]; then
		info "building $variant $arch image via docker..."
		docker build -t sandbox-vm-builder "$REPO_DIR"

		local uid gid
		uid="$(id -u)"
		gid="$(id -g)"
		docker run --rm \
			--device /dev/kvm \
			-v sandbox-vm-nix:/nix \
			-v "$REPO_DIR/dist:/output" \
			sandbox-vm-builder \
			bash -c "nix build .#${package} && cp result/*.qcow2 /output/ && chown $uid:$gid /output/*.qcow2"
	else
		info "building $variant $arch image via nix..."
		nix build "$REPO_DIR#${package}"

		local dir image
		dir="$(readlink "$REPO_DIR/result")"
		image="$(find "$dir" -name '*.qcow2' -print -quit)"
		[ -n "$image" ] || die "no .qcow2 found in $dir"

		cp "$image" "$REPO_DIR/dist/"
	fi

	local output
	# shellcheck disable=SC2012
	output="$(ls -t "${REPO_DIR}/dist/sandbox-${variant}-${arch}-"*.qcow2 2>/dev/null | head -1)" || true
	[ -n "$output" ] || die "no image found in dist/"
	echo "${green}${output}${reset}" >&2
	echo "$output"

	if [ "$sign" = true ]; then
		bash "$SCRIPT_DIR/sign.sh" "$output"
	fi
}

main "$@"

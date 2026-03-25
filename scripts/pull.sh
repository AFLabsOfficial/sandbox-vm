#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
setup_colors

BASE_URL="https://dl.aflabs.org/iso"

# global for cleanup trap
TMPFILE=""
cleanup() {
	[ -n "$TMPFILE" ] && rm -f "$TMPFILE"
	return 0
}
trap cleanup EXIT

usage() {
	cat <<EOF
Usage: pull.sh [options] <variant>

Arguments:
  variant              headless or gui

Options:
  --arch <arch>        x86_64 or aarch64 (default: auto-detect host)
  --version <ver>      Specific version e.g. "v0.1.0" (default: latest)
  --list               List available versions for variant+arch
  --no-pull            Use latest cached image (no network)
  --cache-dir <path>   Override cache directory
  --force              Force re-download even if cached
  -h, --help           Show usage
EOF
	exit "${1:-0}"
}

verify_signature() {
	local hash_file="$1" sig_file="$2"
	if [ ! -f "$sig_file" ]; then
		warn "no .sha256.asc signature found, skipping signature verification"
		return 0
	fi
	if ! command -v gpg &>/dev/null; then
		warn "gpg not found, skipping signature verification"
		return 0
	fi

	# auto-import signing keys from repo if available
	local keys_file="$SCRIPT_DIR/../KEYS"
	if [ -f "$keys_file" ]; then
		gpg --import "$keys_file" 2>/dev/null || true
	fi

	info "verifying signature..."
	if ! gpg --verify "$sig_file" "$hash_file" 2>/dev/null; then
		die "signature verification failed for $hash_file"
	fi
	info "signature ok"
}

verify_hash() {
	local file="$1" hash_file="$2"
	if [ ! -f "$hash_file" ]; then
		warn "no .sha256 file found, skipping verification"
		return 0
	fi
	info "verifying sha256..."
	local expected actual
	expected=$(awk '{print $1}' "$hash_file")
	actual=$(sha256_file "$file")
	if [ "$expected" != "$actual" ]; then
		rm -f "$file"
		die "sha256 mismatch! expected: $expected, actual: $actual"
	fi
	info "sha256 ok: $actual"
}

main() {
	local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/sandbox-vm"
	local arch="" version="" list=false force=false no_pull=false variant=""

	while [ $# -gt 0 ]; do
		case "$1" in
		--arch)
			arch="$2"
			shift 2
			;;
		--version)
			version="$2"
			shift 2
			;;
		--list)
			list=true
			shift
			;;
		--no-pull)
			no_pull=true
			shift
			;;
		--cache-dir)
			cache_dir="$2"
			shift 2
			;;
		--force)
			force=true
			shift
			;;
		-h | --help) usage ;;
		-*)
			echo "${red}error:${reset} unknown option: $1" >&2
			usage 1
			;;
		*)
			if [ -z "$variant" ]; then
				variant="$1"
				shift
			else
				echo "${red}error:${reset} unexpected argument: $1" >&2
				usage 1
			fi
			;;
		esac
	done

	[ -n "$variant" ] || die "variant is required (headless or gui)"
	case "$variant" in
	headless | gui) ;;
	*) die "variant must be headless or gui, got: $variant" ;;
	esac

	arch=$(normalize_arch "$arch")
	require_cmd curl

	local image_re="sandbox-${variant}-${arch}-v[0-9]+\.[0-9]+\.[0-9]+[^-]*-[0-9]{8}\.[0-9a-f]+\.qcow2"

	# list mode
	if [ "$list" = true ]; then
		local listing
		listing=$(curl -fsSL "$BASE_URL/")
		echo "$listing" | grep -oE "$image_re" | sort -u
		return 0
	fi

	mkdir -p "$cache_dir"

	# no-pull mode: use latest cached image
	if [ "$no_pull" = true ]; then
		local cached
		cached=$(find "$cache_dir" -maxdepth 1 -name "*.qcow2" |
			xargs -r -n1 basename |
			grep -E "$image_re" |
			sort -V | tail -1)
		[ -n "$cached" ] || die "no cached image found for ${variant}/${arch}"
		info "cached: $cached"
		echo "$cache_dir/$cached"
		return 0
	fi

	# resolve filename from directory listing
	local listing filename
	listing=$(curl -fsSL "$BASE_URL/")
	if [ -n "$version" ]; then
		filename=$(echo "$listing" |
			grep -oE "$image_re" |
			grep "sandbox-${variant}-${arch}-${version}-" |
			head -1)
		[ -n "$filename" ] || die "no image found for ${variant}/${arch} version ${version}"
	else
		filename=$(echo "$listing" |
			grep -oE "$image_re" |
			sort -V | tail -1)
		[ -n "$filename" ] || die "no image found for ${variant}/${arch}"
	fi

	local hashname signame url hash_url sig_url dest hash_dest sig_dest
	hashname="${filename%.qcow2}.sha256"
	signame="${hashname}.asc"
	url="$BASE_URL/$filename"
	hash_url="$BASE_URL/$hashname"
	sig_url="$BASE_URL/$signame"
	dest="$cache_dir/$filename"
	hash_dest="$cache_dir/$hashname"
	sig_dest="$cache_dir/$signame"

	if [ -f "$dest" ] && [ "$force" != true ]; then
		info "cached: $filename"
		echo "$dest"
		return 0
	fi

	info "downloading: $filename"
	TMPFILE="$cache_dir/.pull-$$-$filename"
	curl -f --progress-bar -o "$TMPFILE" "$url"
	curl -fsSL -o "$hash_dest" "$hash_url" 2>/dev/null || true
	curl -fsSL -o "$sig_dest" "$sig_url" 2>/dev/null || true
	verify_signature "$hash_dest" "$sig_dest"
	verify_hash "$TMPFILE" "$hash_dest"
	mv "$TMPFILE" "$dest"
	TMPFILE=""
	echo "$dest"
}

main "$@"

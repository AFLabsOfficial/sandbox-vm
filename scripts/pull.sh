#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
setup_colors

BASE_URL="https://dl.aflabs.org/iso"

# globals for cleanup trap
TMP_IMG=""
TMP_HASH=""
TMP_SIG=""
cleanup() {
	[ -n "$TMP_IMG" ] && rm -f "$TMP_IMG"
	[ -n "$TMP_HASH" ] && rm -f "$TMP_HASH"
	[ -n "$TMP_SIG" ] && rm -f "$TMP_SIG"
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
	[ -f "$sig_file" ] || die "missing signature file: $sig_file"

	if ! command -v gpg &>/dev/null; then
		warn "gpg not installed; skipping signature verification"
		warn "sha256 alone does not authenticate against a network attacker"
		return 0
	fi

	local keys_file="$SCRIPT_DIR/../KEYS"
	[ -f "$keys_file" ] || die "missing KEYS file: $keys_file"
	gpg --import "$keys_file" 2>/dev/null || die "failed to import KEYS"

	info "verifying signature..."
	gpg --verify "$sig_file" "$hash_file" 2>/dev/null ||
		die "signature verification failed for $hash_file"
	info "signature ok"
}

verify_hash() {
	local file="$1" hash_file="$2"
	[ -f "$hash_file" ] || die "missing hash file: $hash_file"
	info "verifying sha256..."
	local expected actual
	expected=$(awk '{print $1}' "$hash_file")
	actual=$(sha256_file "$file")
	if [ "$expected" != "$actual" ]; then
		die "sha256 mismatch! expected: $expected, actual: $actual"
	fi
	info "sha256 ok: $actual"
}

# resolve latest matching filename from server listing.
# echoes filename on stdout; returns curl exit code on failure.
resolve_from_server() {
	local variant="$1" arch="$2" version="$3" image_re="$4"
	local listing
	listing=$(curl -fsSL --connect-timeout 5 "$BASE_URL/" 2>/dev/null) || return $?
	if [ -n "$version" ]; then
		echo "$listing" | { grep -oE "$image_re" || true; } |
			{ grep "sandbox-${variant}-${arch}-${version}-" || true; } | head -1
	else
		echo "$listing" | { grep -oE "$image_re" || true; } | sort -V | tail -1
	fi
	return 0
}

# resolve latest matching filename from cache.
resolve_from_cache() {
	local variant="$1" arch="$2" version="$3" image_re="$4" cache_dir="$5"
	local re="$image_re"
	[ -n "$version" ] &&
		re="sandbox-${variant}-${arch}-${version}-[0-9]{8}\.[0-9a-f]+\.qcow2"
	find "$cache_dir" -maxdepth 1 -name '*.qcow2' 2>/dev/null |
		while read -r p; do basename "$p"; done |
		{ grep -E "$re" || true; } | sort -V | tail -1
	return 0
}

# verify a cached image against its sidecars.
verify_cached() {
	local image_path="$1"
	local hash_path="${image_path%.qcow2}.sha256"
	local sig_path="${hash_path}.asc"
	[ -f "$hash_path" ] ||
		die "cached image $image_path has no .sha256 sidecar; re-run with --force"
	[ -f "$sig_path" ] ||
		die "cached image $image_path has no .sha256.asc sidecar; re-run with --force"
	verify_signature "$hash_path" "$sig_path"
	verify_hash "$image_path" "$hash_path"
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

	# list mode: listing is the product, network is mandatory
	if [ "$list" = true ]; then
		local listing
		listing=$(curl -fsSL "$BASE_URL/")
		echo "$listing" | grep -oE "$image_re" | sort -u
		return 0
	fi

	mkdir -p "$cache_dir"

	# --no-pull: skip network entirely, verify from cache
	if [ "$no_pull" = true ]; then
		local cached
		cached=$(resolve_from_cache "$variant" "$arch" "$version" "$image_re" "$cache_dir")
		[ -n "$cached" ] ||
			die "no cached image found for ${variant}/${arch}${version:+ $version}"
		info "cached: $cached"
		verify_cached "$cache_dir/$cached"
		echo "$cache_dir/$cached"
		return 0
	fi

	# try to resolve latest filename from server; fall back to cache on network failure
	local filename="" curl_rc=0
	set +e
	filename=$(resolve_from_server "$variant" "$arch" "$version" "$image_re")
	curl_rc=$?
	set -e
	case $curl_rc in
	0) ;;
	22) die "server returned HTTP 4xx fetching $BASE_URL/" ;;
	*)
		[ "$force" = true ] &&
			die "cannot --force re-download: network unreachable (curl $curl_rc)"
		warn "network unreachable (curl $curl_rc); falling back to cache"
		filename=$(resolve_from_cache "$variant" "$arch" "$version" "$image_re" "$cache_dir")
		[ -n "$filename" ] ||
			die "no cached image matching ${variant}/${arch}${version:+ $version}"
		info "cached: $filename"
		verify_cached "$cache_dir/$filename"
		echo "$cache_dir/$filename"
		return 0
		;;
	esac
	[ -n "$filename" ] ||
		die "no image found for ${variant}/${arch}${version:+ version $version}"

	local hashname signame url hash_url sig_url dest hash_dest sig_dest
	hashname="${filename%.qcow2}.sha256"
	signame="${hashname}.asc"
	url="$BASE_URL/$filename"
	hash_url="$BASE_URL/$hashname"
	sig_url="$BASE_URL/$signame"
	dest="$cache_dir/$filename"
	hash_dest="$cache_dir/$hashname"
	sig_dest="$cache_dir/$signame"

	# cache hit: re-verify with cached sidecars
	if [ -f "$dest" ] && [ "$force" != true ]; then
		info "cached: $filename"
		verify_cached "$dest"
		echo "$dest"
		return 0
	fi

	info "downloading: $filename"
	TMP_IMG="$cache_dir/.pull-$$-$filename"
	TMP_HASH="$cache_dir/.pull-$$-$hashname"
	TMP_SIG="$cache_dir/.pull-$$-$signame"

	# sidecars first: a few KB, tells us early if the release is well-formed
	curl -f -sSL -o "$TMP_HASH" "$hash_url" ||
		die "failed to download $hash_url"
	curl -f -sSL -o "$TMP_SIG" "$sig_url" ||
		die "failed to download $sig_url"
	verify_signature "$TMP_HASH" "$TMP_SIG"

	curl -f --progress-bar -o "$TMP_IMG" "$url"
	verify_hash "$TMP_IMG" "$TMP_HASH"

	# atomic: cache only ever contains fully-verified triplets
	mv "$TMP_IMG" "$dest"
	mv "$TMP_HASH" "$hash_dest"
	mv "$TMP_SIG" "$sig_dest"
	TMP_IMG="" TMP_HASH="" TMP_SIG=""

	echo "$dest"
}

main "$@"

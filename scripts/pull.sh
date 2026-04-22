#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
setup_colors

BASE_URL="https://dl.aflabs.org/iso"

# refuse to follow any redirect off https, even if the server sends one
CURL_OPTS=(--proto '=https' --proto-redir '=https')

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
  --version <ver>      Pin to an exact version e.g. "v0.1.0"
                       (default: latest patch of this repo's major.minor)
  --list               List all available versions for variant+arch
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

# extract vMAJOR.MINOR from flake.nix's version literal, e.g. "0.5".
repo_version_mm() {
	local flake="$SCRIPT_DIR/../flake.nix"
	[ -f "$flake" ] || die "cannot locate flake.nix at $flake"
	local mm
	mm=$(sed -nE 's/^[[:space:]]*version = "v([0-9]+\.[0-9]+)\.[0-9]+[^"]*".*/\1/p' "$flake" | head -1)
	[ -n "$mm" ] || die "could not parse version from $flake"
	echo "$mm"
}

# fetch the index listing from BASE_URL. echoes on stdout, returns curl exit.
fetch_listing() {
	curl "${CURL_OPTS[@]}" -fsSL --connect-timeout 5 "$BASE_URL/" 2>/dev/null
}

# echo the latest match for pin_re in the given listing (sorted by version).
pick_latest() {
	local listing="$1" pin_re="$2"
	echo "$listing" | { grep -oE "$pin_re" || true; } | sort -V | tail -1
}

# warn if server listing has a major.minor strictly newer than repo's.
warn_if_newer_available() {
	local listing="$1" variant="$2" arch="$3" repo_mm="$4"
	local any_re="sandbox-${variant}-${arch}-v[0-9]+\.[0-9]+\.[0-9]+[^-]*-[0-9]{8}\.[0-9a-f]+\.qcow2"
	local newest_mm
	newest_mm=$(echo "$listing" | grep -oE "$any_re" |
		sed -nE 's/.*-v([0-9]+\.[0-9]+)\.[0-9]+.*/\1/p' |
		sort -uV | tail -1)
	[ -n "$newest_mm" ] || return 0
	[ "$newest_mm" = "$repo_mm" ] && return 0
	# newest > repo iff the two-line sort -V puts newest last
	if [ "$(printf '%s\n%s\n' "$repo_mm" "$newest_mm" | sort -V | tail -1)" = "$newest_mm" ]; then
		warn "newer version v${newest_mm}.x available on server (this repo is v${repo_mm}.x)"
		info "  bump version in flake.nix and pull to upgrade"
	fi
}

# echo latest cached filename matching pin_re.
resolve_from_cache() {
	local cache_dir="$1" pin_re="$2"
	find "$cache_dir" -maxdepth 1 -name '*.qcow2' 2>/dev/null |
		while read -r p; do basename "$p"; done |
		{ grep -E "$pin_re" || true; } | sort -V | tail -1
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

	# reject anything that isn't strict semver before it hits a regex interpolation
	if [ -n "$version" ]; then
		[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
			die "--version must be a strict semver like v0.5.1, got: $version"
	fi

	arch=$(normalize_arch "$arch")
	require_cmd curl

	# any_re = all published versions (used by --list).
	# pin_re = what we'll actually pull: default to repo's major.minor; --version overrides.
	local any_re="sandbox-${variant}-${arch}-v[0-9]+\.[0-9]+\.[0-9]+[^-]*-[0-9]{8}\.[0-9a-f]+\.qcow2"
	local pin_re pin_desc repo_mm=""
	if [ -n "$version" ]; then
		# escape dots so the literal version doesn't match too broadly as ERE
		local version_re="${version//./\\.}"
		pin_re="sandbox-${variant}-${arch}-${version_re}-[0-9]{8}\.[0-9a-f]+\.qcow2"
		pin_desc="$version"
	else
		repo_mm=$(repo_version_mm)
		pin_re="sandbox-${variant}-${arch}-v${repo_mm}\.[0-9]+[^-]*-[0-9]{8}\.[0-9a-f]+\.qcow2"
		pin_desc="v${repo_mm}.x"
	fi

	# list mode: show all published versions for variant+arch, not just the pin.
	if [ "$list" = true ]; then
		local listing
		listing=$(curl "${CURL_OPTS[@]}" -fsSL "$BASE_URL/")
		echo "$listing" | grep -oE "$any_re" | sort -u
		return 0
	fi

	mkdir -p "$cache_dir"

	# --no-pull: skip network entirely, verify from cache
	if [ "$no_pull" = true ]; then
		local cached
		cached=$(resolve_from_cache "$cache_dir" "$pin_re")
		[ -n "$cached" ] ||
			die "no cached image for ${variant}/${arch} ${pin_desc}"
		info "cached: $cached"
		verify_cached "$cache_dir/$cached"
		echo "$cache_dir/$cached"
		return 0
	fi

	# try server; pick by pin_re. warn if newer major.minor exists on server.
	local listing="" filename="" curl_rc=0
	set +e
	listing=$(fetch_listing)
	curl_rc=$?
	set -e
	case $curl_rc in
	0)
		filename=$(pick_latest "$listing" "$pin_re")
		# skip the newer-warning when --version was explicit: user asked for it
		[ -z "$version" ] &&
			warn_if_newer_available "$listing" "$variant" "$arch" "$repo_mm"
		;;
	22) die "server returned HTTP 4xx fetching $BASE_URL/" ;;
	*)
		[ "$force" = true ] &&
			die "cannot --force re-download: network unreachable (curl $curl_rc)"
		warn "network unreachable (curl $curl_rc); falling back to cache"
		;;
	esac

	# fall back to cache when the server either had no pin match or was unreachable
	if [ -z "$filename" ]; then
		filename=$(resolve_from_cache "$cache_dir" "$pin_re")
		[ -n "$filename" ] ||
			die "no image for ${variant}/${arch} ${pin_desc} (neither server nor cache)"
		info "cached: $filename"
		verify_cached "$cache_dir/$filename"
		echo "$cache_dir/$filename"
		return 0
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
	curl "${CURL_OPTS[@]}" -f -sSL -o "$TMP_HASH" "$hash_url" ||
		die "failed to download $hash_url"
	curl "${CURL_OPTS[@]}" -f -sSL -o "$TMP_SIG" "$sig_url" ||
		die "failed to download $sig_url"
	verify_signature "$TMP_HASH" "$TMP_SIG"

	curl "${CURL_OPTS[@]}" -f --progress-bar -o "$TMP_IMG" "$url"
	verify_hash "$TMP_IMG" "$TMP_HASH"

	# atomic: cache only ever contains fully-verified triplets
	mv "$TMP_IMG" "$dest"
	mv "$TMP_HASH" "$hash_dest"
	mv "$TMP_SIG" "$sig_dest"
	TMP_IMG="" TMP_HASH="" TMP_SIG=""

	echo "$dest"
}

main "$@"

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
# note: in the locked path the shared partial is not tracked here — it
# persists across runs so a re-run can resume via curl -C -. it's only
# removed when verify fails, via UNVERIFIED_PARTIAL below. in the no-flock
# fallback the partial is per-pid and unconditionally cleaned up via
# FALLBACK_PARTIAL
TMP_HASH=""
UNVERIFIED_PARTIAL=""
FALLBACK_PARTIAL=""
cleanup() {
	[ -n "$UNVERIFIED_PARTIAL" ] && rm -f "$UNVERIFIED_PARTIAL"
	[ -n "$FALLBACK_PARTIAL" ] && rm -f "$FALLBACK_PARTIAL"
	[ -n "$TMP_HASH" ] && rm -f "$TMP_HASH"
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
  --prune [N]          Keep only latest N (default 3) per variant+arch, remove the rest
  --cache-dir <path>   Override cache directory
  --force              Force re-download even if cached
  -h, --help           Show usage
EOF
	exit "${1:-0}"
}

verify_hash() {
	local file="$1" hash_file="$2" expected_name="$3"
	[ -f "$hash_file" ] || die "missing hash file: $hash_file"
	info "verifying sha256..."
	local expected_hash signed_name actual
	expected_hash=$(awk '{print $1}' "$hash_file")
	signed_name=$(awk '{print $2}' "$hash_file")
	# bind hash to filename: the .sha256 line is "<hash>  <name>";
	# reject if that name isn't what we asked for
	[ "$signed_name" = "$expected_name" ] ||
		die "hash file binds to wrong filename: $signed_name (expected $expected_name)"
	actual=$(sha256_file "$file")
	[ "$expected_hash" = "$actual" ] ||
		die "sha256 mismatch! expected: $expected_hash, actual: $actual"
	info "sha256 ok: $actual"
}

# acquire an exclusive lock on $1, blocking until it's free. lock is held
# via fd 9 — the kernel releases it when this script exits (or is killed),
# so no stale-lock cleanup is needed. returns 1 if flock(1) is missing,
# letting callers fall back to a per-pid scheme
acquire_image_lock() {
	local lockfile="$1"
	command -v flock &>/dev/null || return 1
	exec 9>"$lockfile"
	if ! flock -n 9; then
		info "another process is downloading the same image; waiting..."
		flock 9 || die "failed to acquire lock: $lockfile"
	fi
	return 0
}

# portable size+mtime query — echoes "<size> <mtime>" to stdout
stat_size_mtime() {
	stat -c '%s %Y' "$1" 2>/dev/null || stat -f '%z %m' "$1"
}

# write a .verified stamp next to a freshly-verified image. future cache
# hits compare size+mtime against this stamp and skip re-running sha256
write_verified_stamp() {
	local file="$1" hash="$2"
	local sm
	sm=$(stat_size_mtime "$file")
	printf 'sha256=%s\nsize=%s\nmtime=%s\n' \
		"$hash" "${sm%% *}" "${sm##* }" >"${file}.verified"
}

# return 0 if file has a .verified stamp whose size+mtime match current state
check_verified_stamp() {
	local file="$1"
	local stamp="${file}.verified"
	[ -f "$stamp" ] || return 1
	local sm expected_size expected_mtime
	sm=$(stat_size_mtime "$file")
	expected_size=$(sed -n 's/^size=//p' "$stamp")
	expected_mtime=$(sed -n 's/^mtime=//p' "$stamp")
	[ -n "$expected_size" ] || return 1
	[ "${sm%% *}" = "$expected_size" ] || return 1
	[ "${sm##* }" = "$expected_mtime" ] || return 1
	return 0
}

# extract vMAJOR.MINOR from flake.nix's version literal, e.g. "0.5"
repo_version_mm() {
	local flake="$SCRIPT_DIR/../flake.nix"
	[ -f "$flake" ] || die "cannot locate flake.nix at $flake"
	local mm
	mm=$(sed -nE 's/^[[:space:]]*version = "v([0-9]+\.[0-9]+)\.[0-9]+[^"]*".*/\1/p' "$flake" | head -1)
	[ -n "$mm" ] || die "could not parse version from $flake"
	echo "$mm"
}

# fetch the index listing from BASE_URL. uses an etag cache so re-runs hit a
# 304 and reuse the saved body when the server hasn't published anything new
fetch_listing() {
	local cache_dir="$1"
	local etag="$cache_dir/.listing.etag"
	local body="$cache_dir/.listing.body"
	local tmp rc
	tmp=$(mktemp "${body}.XXXXXX")
	# run curl outside an `if !` — $? inside an inverted conditional is the
	# exit of `!` (always 0), not the command's, and we need the real code
	curl "${CURL_OPTS[@]}" -fsSL --connect-timeout 5 \
		--etag-save "$etag" --etag-compare "$etag" \
		"$BASE_URL/" >"$tmp" 2>/dev/null
	rc=$?
	if [ "$rc" -ne 0 ]; then
		rm -f "$tmp"
		return "$rc"
	fi
	# curl writes the body on 200 and nothing on 304; replace the cached body
	# only when we got fresh bytes
	if [ -s "$tmp" ]; then
		mv "$tmp" "$body"
	else
		rm -f "$tmp"
	fi
	cat "$body" 2>/dev/null
}

# recent resolution cache: skip the http round-trip entirely when we picked
# the same pin within the last TTL seconds
RESOLUTION_TTL=3600

read_recent_resolution() {
	local cache_dir="$1" variant="$2" arch="$3" pin_re="$4"
	local stamp="$cache_dir/.last-resolve-$variant-$arch"
	[ -f "$stamp" ] || return 1
	local saved_at filename now
	saved_at=$(sed -n 's/^stamp=//p' "$stamp")
	filename=$(sed -n 's/^filename=//p' "$stamp")
	[ -n "$saved_at" ] && [ -n "$filename" ] || return 1
	now=$(date +%s)
	[ $((now - saved_at)) -lt "$RESOLUTION_TTL" ] || return 1
	# user may have bumped flake.nix version — make sure cache still matches pin
	echo "$filename" | grep -qE "$pin_re" || return 1
	echo "$filename"
}

write_recent_resolution() {
	local cache_dir="$1" variant="$2" arch="$3" filename="$4"
	local stamp="$cache_dir/.last-resolve-$variant-$arch"
	printf 'filename=%s\nstamp=%s\n' "$filename" "$(date +%s)" >"$stamp"
}

# echo the latest match for pin_re in the given listing (sorted by version)
pick_latest() {
	local listing="$1" pin_re="$2"
	echo "$listing" | { grep -oE "$pin_re" || true; } | sort -V | tail -1
}

# warn if server listing has a major.minor strictly newer than repo's
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

# echo latest cached filename matching pin_re
resolve_from_cache() {
	local cache_dir="$1" pin_re="$2"
	local -a names=()
	local f name
	shopt -s nullglob
	for f in "$cache_dir"/*.qcow2; do
		name="${f##*/}"
		[[ "$name" =~ $pin_re ]] && names+=("$name")
	done
	shopt -u nullglob
	[ "${#names[@]}" -gt 0 ] || return 0
	printf '%s\n' "${names[@]}" | sort -V | tail -1
}

# drop all but the latest N cached images per (variant, arch) group,
# along with their sha256/verified/partial siblings
prune_cache() {
	local cache_dir="$1" keep="$2"
	local removed=0 groups group files total drop_count to_drop f base
	groups=$(find "$cache_dir" -maxdepth 1 -name 'sandbox-*-v*.qcow2' 2>/dev/null |
		while read -r p; do basename "$p"; done |
		sed -nE 's/^(sandbox-[^-]+-[^-]+)-v[0-9]+.*/\1/p' |
		sort -u)
	for group in $groups; do
		files=$(find "$cache_dir" -maxdepth 1 -name "${group}-v*.qcow2" 2>/dev/null |
			while read -r p; do basename "$p"; done | sort -V)
		total=$(printf '%s\n' "$files" | grep -c . || true)
		[ "$total" -le "$keep" ] && continue
		drop_count=$((total - keep))
		to_drop=$(printf '%s\n' "$files" | head -n "$drop_count")
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			base="${f%.qcow2}"
			info "pruning $f"
			rm -f "$cache_dir/$f" \
				"$cache_dir/${base}.sha256" \
				"$cache_dir/${f}.verified" \
				"$cache_dir/${f}.partial" \
				"$cache_dir/${f}.lock" \
				"$cache_dir/${f}".*.partial
			removed=$((removed + 1))
		done <<<"$to_drop"
	done
	info "pruned $removed image(s), kept $keep per variant+arch"
}

# verify a cached image against its sidecars. fast-paths via .verified
# stamp when size+mtime haven't changed since the last full verify
verify_cached() {
	local image_path="$1"
	local hash_path="${image_path%.qcow2}.sha256"

	if check_verified_stamp "$image_path"; then
		info "verified stamp fresh: $(basename "$image_path")"
		return 0
	fi

	[ -f "$hash_path" ] ||
		die "cached image $image_path has no .sha256 sidecar; re-run with --force"
	verify_hash "$image_path" "$hash_path" "$(basename "$image_path")"
	write_verified_stamp "$image_path" "$(awk '{print $1}' "$hash_path")"
}

main() {
	local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/sandbox-vm"
	local arch="" version="" list=false force=false no_pull=false variant=""
	local prune=false prune_keep=3

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
		--prune)
			prune=true
			# optional int: --prune 5
			if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
				prune_keep="$2"
				shift 2
			else
				shift
			fi
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
		-*) die_usage "unknown option: $1" ;;
		*)
			if [ -z "$variant" ]; then
				variant="$1"
				shift
			else
				die_usage "unexpected argument: $1"
			fi
			;;
		esac
	done

	# --prune doesn't need a variant; it operates on the whole cache
	if [ "$prune" = true ]; then
		mkdir -p "$cache_dir"
		chmod 700 "$cache_dir"
		prune_cache "$cache_dir" "$prune_keep"
		return 0
	fi

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

	# --list is an enumeration; combining with --version would narrow to a
	# single already-known filename and is almost certainly a typo
	[ "$list" = true ] && [ -n "$version" ] &&
		die_usage "--list and --version are mutually exclusive"

	arch=$(normalize_arch "$arch")
	require_cmd curl

	# any_re = all published versions (used by --list)
	# pin_re = what we'll actually pull: default to repo's major.minor; --version overrides
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

	# list mode: show all published versions for variant+arch, not just the pin
	if [ "$list" = true ]; then
		local listing
		listing=$(curl "${CURL_OPTS[@]}" -fsSL "$BASE_URL/")
		echo "$listing" | grep -oE "$any_re" | sort -u
		return 0
	fi

	mkdir -p "$cache_dir"
	chmod 700 "$cache_dir"

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

	# fast path: recent resolution cached and image on disk — skip network
	if [ "$force" != true ]; then
		local recent
		recent=$(read_recent_resolution "$cache_dir" "$variant" "$arch" "$pin_re" || true)
		if [ -n "$recent" ] && [ -f "$cache_dir/$recent" ]; then
			info "recent resolution: $recent"
			verify_cached "$cache_dir/$recent"
			echo "$cache_dir/$recent"
			return 0
		fi
	fi

	# try server; pick by pin_re. warn if newer major.minor exists on server
	local listing="" filename="" curl_rc=0
	set +e
	listing=$(fetch_listing "$cache_dir")
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
		write_recent_resolution "$cache_dir" "$variant" "$arch" "$filename"
		echo "$cache_dir/$filename"
		return 0
	fi

	local hashname url hash_url dest hash_dest
	hashname="${filename%.qcow2}.sha256"
	url="$BASE_URL/$filename"
	hash_url="$BASE_URL/$hashname"
	dest="$cache_dir/$filename"
	hash_dest="$cache_dir/$hashname"

	# cache hit: re-verify with cached sidecars
	if [ -f "$dest" ] && [ "$force" != true ]; then
		info "cached: $filename"
		verify_cached "$dest"
		write_recent_resolution "$cache_dir" "$variant" "$arch" "$filename"
		echo "$dest"
		return 0
	fi

	# serialize concurrent pulls of the same image. without this, multiple
	# curls write to the shared $dest.partial with -C -, corrupting it and
	# producing a sha256 mismatch. on systems without flock(1) we fall back
	# to a per-pid partial — wastes bandwidth but avoids the race
	local partial
	if acquire_image_lock "$dest.lock"; then
		# another process may have completed the download while we waited
		if [ -f "$dest" ] && [ "$force" != true ]; then
			info "cached: $filename"
			verify_cached "$dest"
			write_recent_resolution "$cache_dir" "$variant" "$arch" "$filename"
			echo "$dest"
			return 0
		fi
		partial="$dest.partial"
	else
		warn "flock(1) not available; using per-pid partial (no cross-run resume)"
		partial="$dest.$$.partial"
		FALLBACK_PARTIAL="$partial"
	fi

	info "downloading: $filename"
	TMP_HASH="$cache_dir/.pull-$$-$hashname"

	# sidecar first: a few KB, tells us early if the release is well-formed
	curl "${CURL_OPTS[@]}" -f -sSL -o "$TMP_HASH" "$hash_url" ||
		die "failed to download $hash_url"

	# qcow2: resume-capable. partial persists on interrupt so a re-run
	# continues from where we stopped. --retry handles flaky networks
	curl "${CURL_OPTS[@]}" -f --progress-bar -C - --retry 5 --retry-connrefused --retry-delay 3 \
		-o "$partial" "$url" ||
		die "download failed (partial kept at $partial for resume)"

	# curl succeeded — from here on, partial is removable on failure
	UNVERIFIED_PARTIAL="$partial"
	verify_hash "$partial" "$TMP_HASH" "$filename"
	UNVERIFIED_PARTIAL=""

	# promote: track $dest via UNVERIFIED_PARTIAL and retarget TMP_HASH at
	# its final path, so the cleanup trap unwinds a partially-promoted
	# pair if we die between moves
	mv "$partial" "$dest"
	FALLBACK_PARTIAL=""
	UNVERIFIED_PARTIAL="$dest"
	mv "$TMP_HASH" "$hash_dest"
	TMP_HASH="$hash_dest"
	# full pair present — clear all trackers so cleanup leaves it alone
	UNVERIFIED_PARTIAL="" TMP_HASH=""

	# write stamp so future launches hit the fast path in verify_cached
	write_verified_stamp "$dest" "$(awk '{print $1}' "$hash_dest")"
	write_recent_resolution "$cache_dir" "$variant" "$arch" "$filename"

	echo "$dest"
}

main "$@"

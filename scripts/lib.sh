#!/usr/bin/env bash
# shared helpers for sandbox-vm scripts

# runtime defaults — the justfile mirrors these, keep them in sync
# shellcheck disable=SC2034 # used by sourcing scripts
SANDBOX_DEFAULT_PORT=22022
# shellcheck disable=SC2034
SANDBOX_DEFAULT_MEMORY=4G
# shellcheck disable=SC2034
SANDBOX_DEFAULT_CPUS=2

# shellcheck disable=SC2034 # used by sourcing scripts
setup_colors() {
	if [ -t 2 ]; then
		red=$'\033[31m'
		green=$'\033[32m'
		yellow=$'\033[33m'
		cyan=$'\033[36m'
		bold=$'\033[1m'
		reset=$'\033[0m'
	else
		red="" green="" yellow="" cyan="" bold="" reset=""
	fi
}

die() {
	echo "${red}error:${reset} $*" >&2
	exit 1
}

# emit an error message and delegate to the sourcing script's usage() for
# the help text + nonzero exit
die_usage() {
	echo "${red}error:${reset} $*" >&2
	usage 1
}

warn() {
	echo "${yellow}warning:${reset} $*" >&2
}

info() {
	echo "${cyan}$*${reset}" >&2
}

normalize_arch() {
	local arch="${1:-$(uname -m)}"
	case "$arch" in
	x86_64 | amd64) echo "x86_64" ;;
	aarch64 | arm64) echo "aarch64" ;;
	*) die "unsupported architecture: $arch" ;;
	esac
}

sha256_file() {
	local out
	if command -v sha256sum &>/dev/null; then
		out=$(sha256sum "$1")
	elif command -v shasum &>/dev/null; then
		out=$(shasum -a 256 "$1")
	else
		die "sha256sum or shasum required"
	fi
	echo "${out%% *}"
}

require_cmd() {
	command -v "$1" &>/dev/null || die "$1 not found${2:+ ($2)}"
}

# stable hash of all file contents and relative paths in a directory tree;
# returns "none" if the dir does not exist. used by install_skill so a change
# anywhere in the skill tree (SKILL.md, references/, scripts/) triggers an
# update, not just SKILL.md
dir_content_hash() {
	local dir="$1"
	[ -d "$dir" ] || {
		echo "none"
		return
	}
	if command -v sha256sum &>/dev/null; then
		(cd "$dir" && find . -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum | awk '{print $1}'
	elif command -v shasum &>/dev/null; then
		(cd "$dir" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) | shasum -a 256 | awk '{print $1}'
	else
		die "sha256sum or shasum required"
	fi
}

# install or update a skill into <target_root>/skills/<name>/, copying from
# <source_dir>. content is compared via a hash of the full source tree;
# identical installs are a no-op. on update the target dir is replaced
# (not merged) so removed files stay removed
install_skill() {
	local source_dir="$1" target_root="$2"
	local skill_name target_dir source_hash target_hash action

	skill_name=$(basename "$source_dir")
	target_dir="$target_root/skills/$skill_name"

	[ -f "$source_dir/SKILL.md" ] || return 0

	source_hash=$(dir_content_hash "$source_dir")
	target_hash=$(dir_content_hash "$target_dir")
	[ "$source_hash" = "$target_hash" ] && return 0

	action="installing"
	[ -d "$target_dir" ] && action="updating"
	info "$action $skill_name skill at $target_dir"

	rm -rf "$target_dir"
	mkdir -p "$target_dir"
	cp -R "$source_dir/." "$target_dir/"
}

# cross-platform check whether a TCP port is in use
port_in_use() {
	local port="$1"
	if command -v ss &>/dev/null; then
		ss -tln 2>/dev/null | grep -q ":${port}\b"
	elif command -v lsof &>/dev/null; then
		lsof -iTCP:"$port" -sTCP:LISTEN -P -n &>/dev/null
	else
		# fallback: try connecting
		(echo >/dev/tcp/localhost/"$port") 2>/dev/null
	fi
}

# print the derivations a `nix build --dry-run` plan (its stderr, saved to a
# file) says will be built, one per line. the plan is human-readable nix
# output; no nix command emits it as json (see NixOS/nix#3946), which is why
# the pinned ci nix image matters here
plan_builds() {
	local line in_list=0
	while IFS= read -r line; do
		case "$line" in
		"these "*" derivations will be built:" | "this derivation will be built:") in_list=1 ;;
		"  /nix/store/"*.drv)
			if [ "$in_list" = 1 ]; then
				echo "${line#  }"
			fi
			;;
		*) in_list=0 ;;
		esac
	done <"$1"
}

# from `nix derivation show` json, print the derivations that compile
# something, as `<drv>^*` installables. those have a src, and are not the
# trivial local-only kind nixos generates for config files, units and scripts,
# which depend on most of the closure, so building them would mean downloading
# the whole image, and none of them is where a bump breaks
#
# attributes live in .env, or in .structuredAttrs for derivations that use
# __structuredAttrs, with "1"/"" strings in the former and booleans in the latter
select_packages() {
	# shellcheck disable=SC2016 # ${n} is nix interpolation, not bash
	nix eval --impure --raw --expr '
		let
			j = builtins.fromJSON (builtins.readFile "'"$1"'");
			drvs = j.derivations or j;
			attrs = d: (d.env or { }) // (d.structuredAttrs or { });
			isPackage = d:
				let a = attrs d; in
				(a ? src || a ? srcs)
				&& !(builtins.elem (a.preferLocalBuild or false) [ true "1" ])
				&& !(builtins.elem (a.allowSubstitutes or true) [ false "" ]);
			abs = n: if builtins.substring 0 1 n == "/" then n else "/nix/store/${n}";
		in
		builtins.concatStringsSep ""
			(map (n: "${abs n}^*\n") (builtins.filter (n: isPackage drvs.${n}) (builtins.attrNames drvs)))'
}

# /nix/store/<hash>-<name>-<version>.drv, with or without ^*, -> <name>-<version>
package_name() {
	local name="${1##*/}"
	name="${name#*-}"
	name="${name%^\*}"
	echo "${name%.drv}"
}

# dry-run an installable and print the packages it would have to build, per
# select_packages. dies with the nix output when evaluation fails. <tmp_dir>
# keeps the plan and the derivation json for the caller
uncached_packages() {
	local installable="$1" tmp_dir="$2"
	local drvs=()

	if ! nix build --no-link --dry-run "$installable" 2>"$tmp_dir/plan"; then
		cat "$tmp_dir/plan" >&2
		die "evaluating $installable failed"
	fi

	# NOTE:(@janezicmatej) both nix commands fall back to the flake's default
	# package when given no paths, which this flake does not have
	mapfile -t drvs < <(plan_builds "$tmp_dir/plan")
	[ ${#drvs[@]} -gt 0 ] || return 0

	nix derivation show "${drvs[@]}" >"$tmp_dir/drvs.json"
	select_packages "$tmp_dir/drvs.json"
}

# the quoted value of the first `version = "...";` line in <file> matching the
# extended regex <pattern>, without quotes
version_binding() {
	local line
	line=$(grep -m1 -E "$2" "$1") || die "no version binding found in $1"
	line="${line#*\"}"
	echo "${line%%\"*}"
}

# the `version = "vX.Y.Z";` binding in flake.nix. reads <file> when given,
# else flake.nix under REPO_DIR, which callers set
flake_version() {
	version_binding "${1:-$REPO_DIR/flake.nix}" '^[[:space:]]*version = "v[0-9]+\.[0-9]+\.[0-9]+";'
}

# items joined with ", "
join_list() {
	local joined
	joined=$(printf '%s, ' "$@")
	echo "${joined%, }"
}

# create TMP_DIR, removed on exit. a global rather than a local, so the exit
# trap can still see it after the function that set it returned
setup_tmp_dir() {
	TMP_DIR=$(mktemp -d)
	trap 'rm -rf "$TMP_DIR"' EXIT
}

# sha a remote ref points at, empty when the ref does not exist
#
# --exit-code makes ls-remote exit 2 when the ref is absent, so anything else is
# a real failure and must not be mistaken for "not taken yet". call this in a
# plain assignment, never inside $( ) in a test: die would only leave the subshell
# and an unreachable remote would read as an absent ref
remote_ref_sha() {
	local out status=0
	out=$(git ls-remote --exit-code "$1" "$2" 2>/dev/null) || status=$?
	case "$status" in
	0) printf '%s' "${out%%[[:space:]]*}" ;;
	2) printf '' ;;
	*) die "cannot reach the remote to check $2 (git exited $status)" ;;
	esac
}

# WARN:(@janezicmatej) the token ends up in the url, which git prints back on
# some errors; RELEASE_TOKEN must be a masked ci variable
resolve_push_url() {
	if [ -n "${RELEASE_PUSH_URL:-}" ]; then
		echo "$RELEASE_PUSH_URL"
	elif [ -n "${RELEASE_TOKEN:-}" ]; then
		[ -n "${CI_SERVER_HOST:-}" ] && [ -n "${CI_PROJECT_PATH:-}" ] ||
			die "RELEASE_TOKEN set outside ci: pass RELEASE_PUSH_URL instead"
		echo "https://oauth2:${RELEASE_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
	else
		echo origin
	fi
}

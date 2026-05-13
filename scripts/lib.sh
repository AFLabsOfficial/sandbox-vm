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
	if command -v sha256sum &>/dev/null; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum &>/dev/null; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		die "sha256sum or shasum required"
	fi
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

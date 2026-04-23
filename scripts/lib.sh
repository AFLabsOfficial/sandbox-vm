#!/usr/bin/env bash
# shared helpers for sandbox-vm scripts

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

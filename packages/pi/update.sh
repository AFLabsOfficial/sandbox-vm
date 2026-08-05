#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl jq nix
# shellcheck shell=bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_FILE="$SCRIPT_DIR/package.nix"

# keep in sync with the `sources` attrset in package.nix
PLATFORMS=(linux-x64 linux-arm64 darwin-x64 darwin-arm64)

prefetch() {
	local url="$1"
	nix --extra-experimental-features 'nix-command flakes' \
		store prefetch-file --unpack --json "$url" 2>/dev/null | jq -r '.hash'
}

main() {
	# NOTE:(@janezicmatej) the github release is queried rather than npm or
	# pi.dev/api/latest-version: the binaries are release assets, so the tag is
	# the only source that guarantees they exist for the version we pin
	echo "fetching latest version from github..."
	local latest current
	latest=$(curl -sf "https://api.github.com/repos/earendil-works/pi/releases/latest" |
		jq -r '.tag_name' | sed 's/^v//')
	current=$(grep 'version = ' "$PKG_FILE" | head -1 | sed 's/.*"\(.*\)".*/\1/')

	if [[ "$current" == "$latest" ]]; then
		echo "pi already at $latest"
		return 0
	fi

	echo "updating pi: $current -> $latest"

	sed -i "s|version = \"$current\"|version = \"$latest\"|" "$PKG_FILE"

	local slug url new_hash old_hash
	for slug in "${PLATFORMS[@]}"; do
		url="https://github.com/earendil-works/pi/releases/download/v${latest}/pi-${slug}.tar.gz"
		echo "  prefetching $slug..."
		new_hash=$(prefetch "$url")
		old_hash=$(awk -v slug="$slug" '
			$0 ~ "slug = \"" slug "\";" { found=1; next }
			found && /hash = "sha256-/ {
				match($0, /sha256-[A-Za-z0-9+\/]+=*/)
				print substr($0, RSTART, RLENGTH)
				exit
			}
		' "$PKG_FILE")
		sed -i "s|$old_hash|$new_hash|" "$PKG_FILE"
		echo "    $new_hash"
	done

	echo "pi updated to $latest"
}

main "$@"

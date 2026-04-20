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
	echo "fetching latest version from npm..."
	local latest current
	latest=$(curl -sf "https://registry.npmjs.org/@anthropic-ai/claude-code/latest" | jq -r '.version')
	current=$(grep 'version = ' "$PKG_FILE" | head -1 | sed 's/.*"\(.*\)".*/\1/')

	if [[ "$current" == "$latest" ]]; then
		echo "claude-code already at $latest"
		return 0
	fi

	echo "updating claude-code: $current -> $latest"

	sed -i "s|version = \"$current\"|version = \"$latest\"|" "$PKG_FILE"

	local slug url new_hash old_hash
	for slug in "${PLATFORMS[@]}"; do
		url="https://registry.npmjs.org/@anthropic-ai/claude-code-${slug}/-/claude-code-${slug}-${latest}.tgz"
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

	echo "claude-code updated to $latest"
}

main "$@"

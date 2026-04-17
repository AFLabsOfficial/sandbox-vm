#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl jq nodejs prefetch-npm-deps nix-prefetch
# shellcheck shell=bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PKG_FILE="$SCRIPT_DIR/package.nix"
LOCK_FILE="$SCRIPT_DIR/package-lock.json"

cd "$ROOT_DIR"

extract_hash() {
	sed 's/\x1b\[[0-9;]*m//g' | grep 'got:' | tail -1 | grep -oP 'sha256-[A-Za-z0-9+/]+='
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

	local url="https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${latest}.tgz"

	echo "  prefetching source..."
	local base32 src_hash
	base32=$(nix-prefetch-url --unpack "$url" 2>/dev/null)
	src_hash=$(nix hash convert --to sri "sha256:$base32")
	echo "  source: $src_hash"

	echo "  generating package-lock.json..."
	local tmpdir
	tmpdir=$(mktemp -d)
	trap 'rm -rf "$tmpdir"' RETURN
	curl -sf "$url" -o "$tmpdir/pkg.tgz"
	tar xzf "$tmpdir/pkg.tgz" -C "$tmpdir" --strip-components=1
	(cd "$tmpdir" && npm install --package-lock-only --ignore-scripts --no-audit --no-fund 2>/dev/null)
	cp "$tmpdir/package-lock.json" "$LOCK_FILE"

	echo "  computing npm deps hash..."
	local npm_hash
	npm_hash=$(prefetch-npm-deps "$LOCK_FILE" 2>/dev/null)
	echo "  npmDepsHash: $npm_hash"

	local old_src old_npm
	old_src=$(grep 'hash = "sha256-' "$PKG_FILE" | head -1 | grep -oP 'sha256-[A-Za-z0-9+/]+=')
	old_npm=$(grep 'npmDepsHash = "sha256-' "$PKG_FILE" | grep -oP 'sha256-[A-Za-z0-9+/]+=')

	sed -i "s|version = \"$current\"|version = \"$latest\"|" "$PKG_FILE"
	sed -i "s|$old_src|$src_hash|" "$PKG_FILE"
	sed -i "s|$old_npm|$npm_hash|" "$PKG_FILE"

	echo "claude-code updated to $latest"
}

main "$@"

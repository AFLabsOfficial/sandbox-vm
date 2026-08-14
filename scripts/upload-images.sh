#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
setup_colors

# upload the images built in dist/ to a staging directory of their own on the
# deploy host, so a release that never finishes cannot be published later

usage() {
	cat <<EOF
Usage: upload-images.sh [options]

Upload dist/*.qcow2 and their .sha256 sidecars to ~/inc/<id>/ on the deploy host.

Options:
  --id <id>          Staging directory name (default: CI_PIPELINE_ID)
  -h, --help         Show usage

Environment:
  SSH_DEPLOY_HOST    user@host to upload to (required)
  SSH_PORT           ssh port (default: 22)
EOF
	exit "${1:-0}"
}

main() {
	local id="${CI_PIPELINE_ID:-}"

	while [ $# -gt 0 ]; do
		case "$1" in
		--id)
			id="$2"
			shift 2
			;;
		-h | --help) usage ;;
		*) die_usage "unknown option: $1" ;;
		esac
	done

	require_cmd ssh
	require_cmd scp

	[ -n "$id" ] || die "no staging id: pass --id or set CI_PIPELINE_ID"
	[ -n "${SSH_DEPLOY_HOST:-}" ] || die "SSH_DEPLOY_HOST is not set"

	local port="${SSH_PORT:-22}"

	local images=()
	while IFS= read -r -d '' img; do
		images+=("$img")
	done < <(find "$REPO_DIR/dist" -maxdepth 1 -name 'sandbox-*.qcow2' -print0 2>/dev/null)
	[ "${#images[@]}" -gt 0 ] || die "no images in dist/"

	local hashes=()
	local img
	for img in "${images[@]}"; do
		[ -f "${img%.qcow2}.sha256" ] || die "no .sha256 sidecar for $(basename "$img")"
		hashes+=("${img%.qcow2}.sha256")
	done

	info "uploading ${#images[@]} image(s) to $SSH_DEPLOY_HOST:~/inc/$id/"
	ssh -p "$port" "$SSH_DEPLOY_HOST" "mkdir -p ~/inc/'$id'"
	scp -P "$port" "${images[@]}" "${hashes[@]}" "$SSH_DEPLOY_HOST:~/inc/$id/"

	for img in "${images[@]}"; do
		echo "  $(basename "$img")"
	done
}

main "$@"

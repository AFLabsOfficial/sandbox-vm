#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: sign.sh <image.qcow2>"
  exit "${1:-0}"
}

[ "${1:-}" ] || usage 1
[ "$1" = "-h" ] || [ "$1" = "--help" ] && usage

IMAGE="$1"

if [ ! -f "$IMAGE" ]; then
  echo "error: file not found: $IMAGE" >&2
  exit 1
fi

if ! command -v gpg &>/dev/null; then
  echo "error: gpg not found" >&2
  exit 1
fi

name="$(basename "$IMAGE")"
base="${name%.qcow2}"
dir="$(dirname "$IMAGE")"

if command -v sha256sum &>/dev/null; then
  hash=$(sha256sum "$IMAGE" | awk '{print $1}')
else
  hash=$(shasum -a 256 "$IMAGE" | awk '{print $1}')
fi

if [ -t 1 ]; then
  bold=$'\033[1m' reset=$'\033[0m'
else
  bold="" reset=""
fi
echo "${bold}signing:${reset} $IMAGE"
echo "${bold}sha256:${reset} $hash"
echo "$hash  $name" > "$dir/$base.sha256"
gpg --detach-sign --armor "$dir/$base.sha256"

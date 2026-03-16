#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://dl.aflabs.org/iso"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sandbox-vm"
ARCH=""
VERSION=""
LIST=false
FORCE=false
VARIANT=""

usage() {
  cat <<EOF
Usage: pull.sh [options] <variant>

Arguments:
  variant              headless or gui

Options:
  --arch <arch>        x86_64 or aarch64 (default: auto-detect host)
  --version <ver>      Specific version e.g. "fe3265e" (default: latest)
  --list               List available versions for variant+arch
  --cache-dir <path>   Override cache directory
  --force              Force re-download even if cached
  -h, --help           Show usage
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --arch)      ARCH="$2"; shift 2 ;;
    --version)   VERSION="$2"; shift 2 ;;
    --list)      LIST=true; shift ;;
    --cache-dir) CACHE_DIR="$2"; shift 2 ;;
    --force)     FORCE=true; shift ;;
    -h|--help)   usage ;;
    -*)          echo "unknown option: $1" >&2; usage ;;
    *)
      if [ -z "$VARIANT" ]; then
        VARIANT="$1"; shift
      else
        echo "unexpected argument: $1" >&2; usage
      fi
      ;;
  esac
done

if [ -z "$VARIANT" ]; then
  echo "error: variant is required (headless or gui)" >&2
  usage
fi

case "$VARIANT" in
  headless|gui) ;;
  *) echo "error: variant must be headless or gui, got: $VARIANT" >&2; exit 1 ;;
esac

# default to host architecture and normalize
[ -z "$ARCH" ] && ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ARCH="x86_64" ;;
  aarch64|arm64) ARCH="aarch64" ;;
  *)             echo "error: unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

if command -v sha256sum &>/dev/null; then
  sha256() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum &>/dev/null; then
  sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  echo "error: sha256sum or shasum is required" >&2
  exit 1
fi

if ! command -v curl &>/dev/null; then
  echo "error: curl is required" >&2
  exit 1
fi

IMAGE_RE="sandbox-${VARIANT}-${ARCH}-[0-9a-f]+(-dirty)?-[0-9]{8}\.[0-9a-f]+\.qcow2"

# list mode: fetch directory listing and extract matching filenames
if [ "$LIST" = true ]; then
  listing=$(curl -fsSL "$BASE_URL/")
  echo "$listing" | grep -oE "$IMAGE_RE" | sort -u
  exit 0
fi

mkdir -p "$CACHE_DIR"

TMPFILE=""
cleanup() {
  [ -n "$TMPFILE" ] && rm -f "$TMPFILE"
  true
}
trap cleanup EXIT

verify_hash() {
  local file="$1" hash_file="$2"
  if [ ! -f "$hash_file" ]; then
    echo "warning: no .sha256 file found, skipping verification" >&2
    return 0
  fi
  echo "verifying sha256..." >&2
  expected=$(awk '{print $1}' "$hash_file")
  actual=$(sha256 "$file")
  if [ "$expected" != "$actual" ]; then
    echo "error: sha256 mismatch!" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    rm -f "$file"
    exit 1
  fi
  echo "sha256 ok: $actual" >&2
}

# resolve filename from directory listing
listing=$(curl -fsSL "$BASE_URL/")
if [ -n "$VERSION" ]; then
  FILENAME=$(echo "$listing" \
    | grep -oE "$IMAGE_RE" \
    | grep "sandbox-${VARIANT}-${ARCH}-${VERSION}-" \
    | head -1)
  if [ -z "$FILENAME" ]; then
    echo "error: no image found for ${VARIANT}/${ARCH} version ${VERSION}" >&2
    exit 1
  fi
else
  FILENAME=$(echo "$listing" \
    | grep -oE "$IMAGE_RE" \
    | sort -u | tail -1)
  if [ -z "$FILENAME" ]; then
    echo "error: no image found for ${VARIANT}/${ARCH}" >&2
    exit 1
  fi
fi

HASHNAME="${FILENAME%.qcow2}.sha256"
URL="$BASE_URL/$FILENAME"
HASH_URL="$BASE_URL/$HASHNAME"
DEST="$CACHE_DIR/$FILENAME"
HASH_DEST="$CACHE_DIR/$HASHNAME"

if [ -f "$DEST" ] && [ "$FORCE" != true ]; then
  echo "cached: $FILENAME" >&2
  echo "$DEST"
  exit 0
fi

echo "downloading: $FILENAME" >&2
TMPFILE="$CACHE_DIR/.pull-$$-$FILENAME"
curl -f --progress-bar -o "$TMPFILE" "$URL"
curl -fsSL -o "$HASH_DEST" "$HASH_URL" 2>/dev/null || true
verify_hash "$TMPFILE" "$HASH_DEST"
mv "$TMPFILE" "$DEST"
TMPFILE=""
echo "$DEST"

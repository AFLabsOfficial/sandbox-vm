#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ARCH=""
VARIANT=""
DOCKER=false
SIGN=false

usage() {
  cat <<EOF
Usage: build.sh [options]

Options:
  --headless         Build headless variant
  --gui              Build GUI variant
  --arch <arch>      Target architecture (default: host)
  --docker           Build using Docker instead of nix (Linux only, requires KVM)
  -s, --sign         Sign the image after building
  -h, --help         Show usage
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --headless) VARIANT="headless"; shift ;;
    --gui)      VARIANT="gui"; shift ;;
    --arch)     ARCH="$2"; shift 2 ;;
    --docker)   DOCKER=true; shift ;;
    -s|--sign)  SIGN=true; shift ;;
    -h|--help)  usage ;;
    *)          echo "unknown option: $1" >&2; usage 1 ;;
  esac
done

if [ -z "$VARIANT" ]; then
  echo "error: specify --headless or --gui" >&2
  exit 1
fi

# default to host architecture and normalize
[ -z "$ARCH" ] && ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ARCH="x86_64" ;;
  aarch64|arm64) ARCH="aarch64" ;;
  *)             echo "error: unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

PACKAGE="packages.${ARCH}-linux.sandbox-${VARIANT}"

# preflight checks
if [ "$SIGN" = true ]; then
  if ! command -v gpg &>/dev/null; then
    echo "error: --sign requires gpg" >&2
    exit 1
  fi
fi

if [ "$DOCKER" = true ]; then
  if ! command -v docker &>/dev/null; then
    echo "error: docker not found" >&2
    exit 1
  fi

  if [ "$(uname -s)" != "Linux" ]; then
    echo "error: --docker requires Linux (KVM is not available inside Docker on macOS)" >&2
    exit 1
  fi

  if [ ! -e /dev/kvm ]; then
    echo "error: /dev/kvm not found, KVM is required for image builds" >&2
    exit 1
  fi

  HOST_ARCH="$(uname -m)"
  if [ "$ARCH" != "$HOST_ARCH" ]; then
    echo "error: --docker cannot cross-build (host is $HOST_ARCH, target is $ARCH)" >&2
    echo "  use nix with a remote builder for cross-architecture builds" >&2
    exit 1
  fi
else
  if ! command -v nix &>/dev/null; then
    echo "error: nix not found (use --docker to build without nix)" >&2
    exit 1
  fi
fi

mkdir -p "$REPO_DIR/dist"

if [ "$DOCKER" = true ]; then

  echo "building $VARIANT $ARCH image via docker..."
  docker build -t sandbox-vm-builder "$REPO_DIR"

  uid="$(id -u)"
  gid="$(id -g)"
  docker run --rm \
    --device /dev/kvm \
    -v sandbox-vm-nix:/nix \
    -v "$REPO_DIR/dist:/output" \
    sandbox-vm-builder \
    bash -c "nix build .#${PACKAGE} && cp result/*.qcow2 /output/ && chown $uid:$gid /output/*.qcow2"
else
  echo "building $VARIANT $ARCH image via nix..."
  nix build "$REPO_DIR#${PACKAGE}"

  dir="$(readlink "$REPO_DIR/result")"
  image="$(find "$dir" -name '*.qcow2' -print -quit)"
  if [ -z "$image" ]; then
    echo "error: no .qcow2 found in $dir" >&2
    exit 1
  fi

  cp "$image" "$REPO_DIR/dist/"
fi

output="$(find "$REPO_DIR/dist" -name "sandbox-${VARIANT}-${ARCH}-*.qcow2" -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2)"
echo "$output"

if [ "$SIGN" = true ]; then
  bash "$SCRIPT_DIR/sign.sh" "$output"
fi

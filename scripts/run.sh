#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# defaults
SSH_PORT=2222
MEMORY=8G
CPUS=4
MOUNTS=()
CLAUDE_DIR=""
CLAUDE_JSON=""
SSH_KEYS=()
SEED_ISO=""
IMAGE=""
GUEST_ARCH=""
GUI=false

usage() {
  cat <<EOF
Usage: run.sh <image.qcow2> [options]

Options:
  --arch <arch>          Guest architecture (auto-detected from image name)
  --gui                  Launch with graphical display (default: headless)
  --ssh-key <key.pub>    SSH public key (repeatable, auto-generates seed ISO)
  --seed-iso <iso>       Pre-built seed ISO (alternative to --ssh-key)
  --mount <path>         Mount host directory into VM (repeatable)
  --claude <path>        Mount claude config dir writable into VM
  --claude-json <path>   Copy claude.json into mounted claude dir
  --memory <size>        VM memory (default: 8G)
  --cpus <n>             VM CPUs (default: 4)
  --ssh-port <port>      SSH port forward (default: 2222)
EOF
  exit 1
}

[ "${1:-}" ] || usage

IMAGE="$1"
shift

while [ $# -gt 0 ]; do
  case "$1" in
    --arch)       GUEST_ARCH="$2"; shift 2 ;;
    --gui)        GUI=true; shift ;;
    --ssh-key)    SSH_KEYS+=("$2"); shift 2 ;;
    --seed-iso)   SEED_ISO="$2"; shift 2 ;;
    --mount)       MOUNTS+=("$2"); shift 2 ;;
    --claude)      CLAUDE_DIR="$2"; shift 2 ;;
    --claude-json) CLAUDE_JSON="$2"; shift 2 ;;
    --memory)      MEMORY="$2"; shift 2 ;;
    --cpus)       CPUS="$2"; shift 2 ;;
    --ssh-port)   SSH_PORT="$2"; shift 2 ;;
    *)            echo "unknown option: $1"; usage ;;
  esac
done

if [ ! -f "$IMAGE" ]; then
  echo "error: image not found: $IMAGE"
  exit 1
fi

# default to host architecture
if [ -z "$GUEST_ARCH" ]; then
  case "$(uname -m)" in
    x86_64|amd64)  GUEST_ARCH="x86_64" ;;
    aarch64|arm64) GUEST_ARCH="aarch64" ;;
    *)             echo "error: cannot detect guest arch, use --arch"; exit 1 ;;
  esac
fi

case "$GUEST_ARCH" in
  x86_64|amd64)  GUEST_ARCH="x86_64" ;;
  aarch64|arm64) GUEST_ARCH="aarch64" ;;
  *)             echo "error: unsupported architecture: $GUEST_ARCH"; exit 1 ;;
esac

# platform detection
HOST_ARCH=$(uname -m)
OS=$(uname -s)
ACCEL="tcg"

case "$OS" in
  Linux)
    [ -r /dev/kvm ] && ACCEL="kvm"
    ;;
  Darwin)
    # hvf only works when guest matches host
    case "$HOST_ARCH" in
      aarch64|arm64) [ "$GUEST_ARCH" = "aarch64" ] && ACCEL="hvf" ;;
      x86_64|amd64)  [ "$GUEST_ARCH" = "x86_64" ] && ACCEL="hvf" ;;
    esac
    ;;
esac

case "$GUEST_ARCH" in
  x86_64)  QEMU_BIN="qemu-system-x86_64" ;;
  aarch64) QEMU_BIN="qemu-system-aarch64" ;;
esac

# auto-generate seed ISO from SSH key
CLEANUP_SEED=""
if [ "${#SSH_KEYS[@]}" -gt 0 ] && [ -z "$SEED_ISO" ]; then
  SEED_ISO="$(mktemp -d)/seed.iso"
  CLEANUP_SEED="$SEED_ISO"
  bash "$SCRIPT_DIR/make-seed.sh" "$SEED_ISO" "${SSH_KEYS[@]}"
fi

cleanup() {
  [ -n "$CLEANUP_SEED" ] && rm -rf "$(dirname "$CLEANUP_SEED")"
}
trap cleanup EXIT

# build qemu command
QEMU_ARGS=(
  "$QEMU_BIN"
  -accel "$ACCEL"
  -m "$MEMORY"
  -smp "$CPUS"
  -drive "file=$IMAGE,format=qcow2,snapshot=on"
  -nic "user,hostfwd=tcp::${SSH_PORT}-:22"
)

# display mode
if [ "$GUI" = "true" ]; then
  if [ "$GUEST_ARCH" = "aarch64" ]; then
    QEMU_ARGS+=(-device virtio-gpu-pci -device usb-ehci -device usb-kbd -device usb-mouse)
  else
    QEMU_ARGS+=(-device virtio-vga)
  fi
else
  QEMU_ARGS+=(-nographic)
fi

# x86_64 with hardware accel — pass through host CPU features (AVX, etc.)
if [ "$GUEST_ARCH" = "x86_64" ] && [ "$ACCEL" != "tcg" ]; then
  QEMU_ARGS+=(-cpu host)
fi

# aarch64 guest needs machine type and uefi firmware
if [ "$GUEST_ARCH" = "aarch64" ]; then
  if [ "$ACCEL" = "hvf" ]; then
    QEMU_ARGS+=(-machine virt -cpu host)
  else
    QEMU_ARGS+=(-machine virt -cpu max)
  fi

  EFI_CODE=""
  for p in \
    /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
    /usr/local/share/qemu/edk2-aarch64-code.fd \
    /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
    /usr/share/AAVMF/AAVMF_CODE.fd; do
    [ -f "$p" ] && EFI_CODE="$p" && break
  done

  if [ -z "$EFI_CODE" ]; then
    echo "error: aarch64 EFI firmware not found"
    echo "  macos: brew install qemu"
    echo "  linux: apt install qemu-efi-aarch64"
    exit 1
  fi
  QEMU_ARGS+=(-bios "$EFI_CODE")
fi

# seed ISO
if [ -n "$SEED_ISO" ]; then
  QEMU_ARGS+=(-drive "file=$SEED_ISO,format=raw,media=cdrom,readonly=on")
fi

FS_ID=0
for mount_path in "${MOUNTS[@]}"; do
  mount_path=$(realpath "$mount_path")
  name=$(basename "$mount_path")
  QEMU_ARGS+=(
    -virtfs "local,path=$mount_path,mount_tag=mount_$name,security_model=none,id=fs${FS_ID}"
  )
  FS_ID=$((FS_ID + 1))
done

if [ -n "$CLAUDE_DIR" ]; then
  CLAUDE_DIR=$(realpath "$CLAUDE_DIR")
  QEMU_ARGS+=(
    -virtfs "local,path=$CLAUDE_DIR,mount_tag=claude,security_model=none,id=fs${FS_ID}"
  )
fi

if [ -n "$CLAUDE_JSON" ]; then
  QEMU_ARGS+=(-fw_cfg "name=opt/claude.json,file=$CLAUDE_JSON")
fi

echo "---"
echo "Guest: $GUEST_ARCH | Accel: $ACCEL | Display: $([ "$GUI" = "true" ] && echo "gui" || echo "headless")"
echo "SSH: ssh -p $SSH_PORT sandbox@localhost"
echo "---"

exec "${QEMU_ARGS[@]}"

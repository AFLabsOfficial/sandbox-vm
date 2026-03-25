#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
setup_colors

# globals for cleanup trap
CLEANUP_SEED=""
CLEANUP_OVERLAY=""

cleanup() {
	[ -n "$CLEANUP_SEED" ] && rm -rf "$(dirname "$CLEANUP_SEED")"
	[ -n "$CLEANUP_OVERLAY" ] && rm -rf "$CLEANUP_OVERLAY"
	return 0
}
trap cleanup EXIT

usage() {
	cat <<EOF
Usage: run.sh <image.qcow2> [options]

Options:
  --arch <arch>          Guest architecture (auto-detected from image name)
  --gui                  Force graphical display
  --headless             Force headless mode
  --ssh-key <key.pub>    SSH public key (repeatable, auto-generates seed ISO)
  --seed-iso <iso>       Pre-built seed ISO (alternative to --ssh-key)
  --mount <path>         Mount host directory into VM (repeatable)
  --claude               Mount claude config dir (uses CLAUDE_CONFIG_DIR or ~/.config/sandbox-vm/claude)
  --disk-size <size>     Resize guest disk (e.g. 50G, default: image built-in size)
  --memory <size>        VM memory (default: 8G)
  --cpus <n>             VM CPUs (default: 4)
  --ssh-port <port>      SSH port forward (default: 2222)
  -h, --help             Show usage
EOF
	exit "${1:-0}"
}

main() {
	local ssh_port=2222 memory=8G cpus=4 claude=false
	local seed_iso="" image="" guest_arch="" gui="" disk_size=""
	local -a mounts=() ssh_keys=()

	case "${1:-}" in
	-h | --help) usage ;;
	"") usage 1 ;;
	esac
	image="$1"
	shift

	while [ $# -gt 0 ]; do
		case "$1" in
		--arch)
			guest_arch="$2"
			shift 2
			;;
		--gui)
			gui=true
			shift
			;;
		--headless)
			gui=false
			shift
			;;
		--ssh-key)
			ssh_keys+=("$2")
			shift 2
			;;
		--seed-iso)
			seed_iso="$2"
			shift 2
			;;
		--mount)
			mounts+=("$2")
			shift 2
			;;
		--claude)
			claude=true
			shift
			;;
		--disk-size)
			disk_size="$2"
			shift 2
			;;
		--memory)
			memory="$2"
			shift 2
			;;
		--cpus)
			cpus="$2"
			shift 2
			;;
		--ssh-port)
			ssh_port="$2"
			shift 2
			;;
		-h | --help) usage ;;
		*)
			echo "${red}error:${reset} unknown option: $1" >&2
			usage 1
			;;
		esac
	done

	[ -f "$image" ] || die "image not found: $image"

	# auto-detect gui from image filename
	if [ -z "$gui" ]; then
		case "$(basename "$image")" in
		*-gui-*) gui=true ;;
		*) gui=false ;;
		esac
	fi

	guest_arch=$(normalize_arch "$guest_arch")

	# platform detection
	local host_arch os accel qemu_bin
	host_arch=$(uname -m)
	os=$(uname -s)
	accel="tcg"

	case "$os" in
	Linux)
		[ -r /dev/kvm ] && accel="kvm"
		;;
	Darwin)
		# hvf only works when guest matches host
		case "$host_arch" in
		aarch64 | arm64) [ "$guest_arch" = "aarch64" ] && accel="hvf" ;;
		x86_64 | amd64) [ "$guest_arch" = "x86_64" ] && accel="hvf" ;;
		esac
		;;
	esac

	case "$guest_arch" in
	x86_64) qemu_bin="qemu-system-x86_64" ;;
	aarch64) qemu_bin="qemu-system-aarch64" ;;
	esac

	# auto-generate seed ISO from SSH keys
	if [ "${#ssh_keys[@]}" -gt 0 ] && [ -z "$seed_iso" ]; then
		seed_iso="$(mktemp -d)/seed.iso"
		CLEANUP_SEED="$seed_iso"
		bash "$SCRIPT_DIR/make-seed.sh" "$seed_iso" "${ssh_keys[@]}"
	fi

	# create resized overlay when --disk-size is given
	local drive_arg
	if [ -n "$disk_size" ]; then
		CLEANUP_OVERLAY=$(mktemp -d)
		local overlay="$CLEANUP_OVERLAY/overlay.qcow2"
		qemu-img create -f qcow2 -b "$(realpath "$image")" -F qcow2 "$overlay" "$disk_size"
		drive_arg="file=$overlay,format=qcow2"
	else
		drive_arg="file=$image,format=qcow2,snapshot=on"
	fi

	# build qemu command
	local -a qemu_args=(
		"$qemu_bin"
		-accel "$accel"
		-m "$memory"
		-smp "$cpus"
		-drive "$drive_arg"
	)

	local ssh_forward=false
	if [ "$gui" = "true" ]; then
		qemu_args+=(-nic user)
	else
		qemu_args+=(-nic "user,hostfwd=tcp::${ssh_port}-:22")
		ssh_forward=true
	fi

	# display mode
	if [ "$gui" = "true" ]; then
		if [ "$guest_arch" = "aarch64" ]; then
			qemu_args+=(-device virtio-gpu-pci -device usb-ehci -device usb-kbd -device usb-mouse)
		else
			qemu_args+=(-device virtio-vga)
		fi
	else
		qemu_args+=(-nographic)
	fi

	# x86_64 with hardware accel — pass through host CPU features (AVX, etc.)
	if [ "$guest_arch" = "x86_64" ] && [ "$accel" != "tcg" ]; then
		qemu_args+=(-cpu host)
	fi

	# aarch64 guest needs machine type and uefi firmware
	if [ "$guest_arch" = "aarch64" ]; then
		if [ "$accel" = "hvf" ]; then
			qemu_args+=(-machine virt -cpu host)
		else
			qemu_args+=(-machine virt -cpu max)
		fi

		local efi_code=""
		local p
		for p in \
			/opt/homebrew/share/qemu/edk2-aarch64-code.fd \
			/usr/local/share/qemu/edk2-aarch64-code.fd \
			/usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
			/usr/share/AAVMF/AAVMF_CODE.fd; do
			[ -f "$p" ] && efi_code="$p" && break
		done

		if [ -z "$efi_code" ]; then
			die "aarch64 EFI firmware not found (macos: brew install qemu, linux: apt install qemu-efi-aarch64)"
		fi
		qemu_args+=(-bios "$efi_code")
	fi

	# seed ISO
	if [ -n "$seed_iso" ]; then
		qemu_args+=(-drive "file=$seed_iso,format=raw,media=cdrom,readonly=on")
	fi

	local fs_id=0 mount_path name tag
	for mount_path in "${mounts[@]}"; do
		mount_path=$(realpath "$mount_path")
		name=$(basename "$mount_path")
		# 9p tags limited to 31 chars: 2 (prefix) + 29 (name)
		tag="m_${name:0:29}"
		qemu_args+=(
			-virtfs "local,path=$mount_path,mount_tag=$tag,security_model=none,id=fs${fs_id}"
		)
		fs_id=$((fs_id + 1))
	done

	if [ "$claude" = true ]; then
		local claude_dir="${CLAUDE_CONFIG_DIR:-}"
		if [ -z "$claude_dir" ] || [ ! -d "$claude_dir" ]; then
			local fallback="${XDG_CONFIG_HOME:-$HOME/.config}/sandbox-vm/claude"
			mkdir -p "$fallback"
			claude_dir="$fallback"
			warn "CLAUDE_CONFIG_DIR not set or missing, using $fallback"
			info "  run 'claude login' inside the VM to authenticate"
		fi
		claude_dir=$(realpath "$claude_dir")

		qemu_args+=(
			-virtfs "local,path=$claude_dir,mount_tag=claude,security_model=none,id=fs${fs_id}"
		)
		fs_id=$((fs_id + 1))
	fi

	info "---"
	info "Guest: $guest_arch | Accel: $accel | Display: $([ "$gui" = "true" ] && echo "gui" || echo "headless")"
	[ "$ssh_forward" = "true" ] && info "SSH: ssh -p $ssh_port sandbox@localhost"
	info "---"

	exec "${qemu_args[@]}"
}

main "$@"

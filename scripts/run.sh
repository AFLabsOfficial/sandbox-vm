#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
setup_colors

# globals for cleanup trap
QEMU_PID=""
CLEANUP_OVERLAY=""
CLEANUP_TMPDIR=""

cleanup() {
	[ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null && wait "$QEMU_PID" 2>/dev/null
	[ -n "$CLEANUP_OVERLAY" ] && rm -rf "$CLEANUP_OVERLAY"
	[ -n "$CLEANUP_TMPDIR" ] && rm -rf "$CLEANUP_TMPDIR"
	return 0
}
trap cleanup EXIT

usage() {
	cat <<EOF
Usage: run.sh [image.qcow2] [options]

If no image is given, one is pulled automatically based on --gui/--headless.

Options:
  --arch <arch>          Guest architecture (auto-detected from image name)
  --gui                  Force graphical display
  --headless             Force headless mode
  --no-pull              Use latest cached image instead of downloading
  --mount <path>         Mount host directory into VM (repeatable)
  --no-claude            Skip mounting claude config dir
  --disk-size <size>     Resize guest disk (e.g. 50G, default: image built-in size)
  --memory <size>        VM memory (default: 4G)
  --cpus <n>             VM CPUs (default: 2)
  --ssh-port <port>      SSH port forward (default: auto from 22022)
  -h, --help             Show usage
EOF
	exit "${1:-0}"
}

main() {
	local ssh_port="" memory=4G cpus=2 claude=true no_pull=false
	local image="" guest_arch="" gui="" disk_size=""
	local -a mounts=()

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
		--no-pull)
			no_pull=true
			shift
			;;
		--mount)
			mounts+=("$2")
			shift 2
			;;
		--no-claude)
			claude=false
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
		-*)
			echo "${red}error:${reset} unknown option: $1" >&2
			usage 1
			;;
		*)
			if [ -z "$image" ]; then
				image="$1"
				shift
			else
				echo "${red}error:${reset} unexpected argument: $1" >&2
				usage 1
			fi
			;;
		esac
	done

	# auto-pull if no image provided
	if [ -z "$image" ]; then
		local variant
		case "$gui" in
		true) variant="gui" ;;
		false) variant="headless" ;;
		"") variant="headless"; gui=false ;;
		esac
		local -a pull_args=()
		[ "$no_pull" = true ] && pull_args+=("--no-pull")
		image=$(bash "$SCRIPT_DIR/pull.sh" "${pull_args[@]}" "$variant")
	fi

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

	# auto-allocate ssh port for headless
	if [ "$gui" != "true" ] && [ -z "$ssh_port" ]; then
		ssh_port=22022
		while port_in_use "$ssh_port"; do
			ssh_port=$((ssh_port + 1))
		done
	fi

	# build networking arg
	local nic_arg="user"
	if [ -n "$ssh_port" ]; then
		nic_arg="user,hostfwd=tcp::${ssh_port}-:22"
	fi

	# build qemu command
	local -a qemu_args=(
		"$qemu_bin"
		-accel "$accel"
		-m "$memory"
		-smp "$cpus"
		-drive "$drive_arg"
		-nic "$nic_arg"
	)

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
	[ -n "$ssh_port" ] && info "SSH: ssh -p $ssh_port sandbox@localhost"
	info "---"

	if [ "$gui" = "true" ]; then
		exec "${qemu_args[@]}"
	fi

	# headless: start qemu in background and auto-ssh
	"${qemu_args[@]}" &>/dev/null &
	QEMU_PID=$!

	# generate throwaway ssh key (vm accepts any key)
	CLEANUP_TMPDIR=$(mktemp -d)
	local ssh_key="$CLEANUP_TMPDIR/id_ed25519"
	ssh-keygen -t ed25519 -f "$ssh_key" -N "" -q

	info "waiting for vm (port $ssh_port)..."
	local attempts=0
	while ! (echo > /dev/tcp/localhost/"$ssh_port") 2>/dev/null; do
		attempts=$((attempts + 1))
		[ $attempts -gt 60 ] && die "vm did not become ready in 60s"
		kill -0 "$QEMU_PID" 2>/dev/null || die "qemu exited unexpectedly"
		sleep 1
	done

	ssh -p "$ssh_port" -t \
		-i "$ssh_key" \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		-o LogLevel=ERROR \
		sandbox@localhost
}

main "$@"

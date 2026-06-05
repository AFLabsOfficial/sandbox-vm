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
VM_READY=false

cleanup() {
	[ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null && wait "$QEMU_PID" 2>/dev/null
	[ -n "$CLEANUP_OVERLAY" ] && rm -rf "$CLEANUP_OVERLAY"
	# preserve the tmpdir on abnormal exit so the qemu log survives for
	# inspection; normal cleanup happens once the vm reached the user
	if [ -n "$CLEANUP_TMPDIR" ]; then
		if [ "$VM_READY" = true ]; then
			rm -rf "$CLEANUP_TMPDIR"
		else
			echo "qemu log preserved: $CLEANUP_TMPDIR/qemu.log" >&2
		fi
	fi
	return 0
}
trap cleanup EXIT

# resolved at preflight: `timeout` (gnu coreutils, linux) or `gtimeout`
# (brew install coreutils on macos)
TIMEOUT_BIN=""

# returns 0 once the guest's sshd has started speaking (first bytes are "SSH-"),
# non-zero while the port is either unreachable or still silent
awaiting_ssh_banner() {
	local port="$1"
	local banner
	banner=$("$TIMEOUT_BIN" 2 bash -c "exec 3<>/dev/tcp/localhost/$port; head -c 4 <&3" 2>/dev/null) || return 1
	[ "$banner" = "SSH-" ]
}

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
  --no-codex             Skip mounting codex config dir
  --disk-size <size>     Resize guest disk (e.g. 50G, default: image built-in size)
  --memory <size>        VM memory (default: 4G)
  --cpus <n>             VM CPUs (default: 2)
  --ssh-port <port>      SSH port forward (default: auto from 22022)
  -h, --help             Show usage
EOF
	exit "${1:-0}"
}

main() {
	[ "$EUID" -eq 0 ] && die "run.sh must not run as root"

	# gnu coreutils: `timeout` on linux, `gtimeout` on macos via brew
	TIMEOUT_BIN=$(command -v timeout || command -v gtimeout) ||
		die "timeout(1) not found; on macos: brew install coreutils"

	local ssh_port="" memory="$SANDBOX_DEFAULT_MEMORY" cpus="$SANDBOX_DEFAULT_CPUS"
	local claude=true codex=true no_pull=false
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
		--no-codex)
			codex=false
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
		-*) die_usage "unknown option: $1" ;;
		*)
			if [ -z "$image" ]; then
				image="$1"
				shift
			else
				die_usage "unexpected argument: $1"
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
		"")
			variant="headless"
			gui=false
			;;
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

	# platform detection — tcg,thread=multi so -smp parallelises across host cores
	local host_arch os accel qemu_bin hw_accel=false
	host_arch=$(uname -m)
	os=$(uname -s)
	accel="tcg,thread=multi"

	case "$os" in
	Linux)
		# -r (readable) not -e (exists): we use kvm in-process so access is the
		# actual prerequisite; build.sh uses -e because docker mounts the device
		if [ -r /dev/kvm ]; then
			accel="kvm"
			hw_accel=true
		fi
		;;
	Darwin)
		# hvf only works when guest matches host
		case "$host_arch" in
		aarch64 | arm64) [ "$guest_arch" = "aarch64" ] && accel="hvf" && hw_accel=true ;;
		x86_64 | amd64) [ "$guest_arch" = "x86_64" ] && accel="hvf" && hw_accel=true ;;
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
		drive_arg="if=none,id=hd0,file=$overlay,format=qcow2,cache=writeback,aio=threads,discard=unmap,detect-zeroes=unmap"
	else
		drive_arg="if=none,id=hd0,file=$image,format=qcow2,snapshot=on,cache=writeback,aio=threads,discard=unmap,detect-zeroes=unmap"
	fi

	# auto-allocate ssh port for headless
	if [ "$gui" != "true" ] && [ -z "$ssh_port" ]; then
		ssh_port=$SANDBOX_DEFAULT_PORT
		while port_in_use "$ssh_port"; do
			ssh_port=$((ssh_port + 1))
		done
	fi

	# build networking arg
	local nic_arg="user,model=virtio-net-pci"
	if [ -n "$ssh_port" ]; then
		nic_arg="user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${ssh_port}-:22"
	fi

	# build qemu command
	local -a qemu_args=(
		"$qemu_bin"
		-accel "$accel"
		-m "$memory"
		-smp "$cpus"
		-drive "$drive_arg"
		-device "virtio-blk-pci,drive=hd0"
		-device virtio-rng-pci
		-nic "$nic_arg"
	)

	# -sandbox needs libseccomp; qemu's seccomp backend is linux-only, so
	# skip it on macos (hvf) or anywhere qemu was built without the feature
	if [ "$os" = "Linux" ]; then
		qemu_args+=(-sandbox "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny")
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
	if [ "$guest_arch" = "x86_64" ] && [ "$hw_accel" = true ]; then
		qemu_args+=(-cpu host)
	fi

	# aarch64 guest needs machine type and uefi firmware
	if [ "$guest_arch" = "aarch64" ]; then
		if [ "$hw_accel" = true ]; then
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
		# pre-check: bsd realpath silently accepts nonexistent paths,
		# which would surface much later as an opaque qemu error
		[ -e "$mount_path" ] || die "--mount path does not exist: $mount_path"
		mount_path=$(realpath "$mount_path")
		# qemu parses -virtfs as csv, a comma in the path would inject options
		case "$mount_path" in
		*,*) die "--mount path may not contain commas: $mount_path" ;;
		esac
		name=$(basename "$mount_path")
		# 9p tags limited to 31 chars: 2 (prefix) + 29 (name)
		tag="m_${name:0:29}"
		qemu_args+=(
			-virtfs "local,path=$mount_path,mount_tag=$tag,security_model=none,id=fs${fs_id}"
		)
		fs_id=$((fs_id + 1))
	done

	local skill_source="$SCRIPT_DIR/../skills/sandbox-vm"

	if [ "$claude" = true ]; then
		local claude_dir="${CLAUDE_CONFIG_DIR:-}"
		if [ -z "$claude_dir" ]; then
			claude_dir="${XDG_CONFIG_HOME:-$HOME/.config}/sandbox-vm/claude"
			warn "CLAUDE_CONFIG_DIR not set, using $claude_dir"
		fi
		mkdir -p "$claude_dir"
		claude_dir=$(realpath "$claude_dir")
		case "$claude_dir" in
		*,*) die "claude config dir may not contain commas: $claude_dir" ;;
		esac

		install_skill "$skill_source" "$claude_dir"

		qemu_args+=(
			-virtfs "local,path=$claude_dir,mount_tag=claude,security_model=none,id=fs${fs_id}"
		)
		fs_id=$((fs_id + 1))
	fi

	if [ "$codex" = true ]; then
		local codex_dir="${CODEX_HOME:-}"
		if [ -z "$codex_dir" ]; then
			codex_dir="${XDG_CONFIG_HOME:-$HOME/.config}/sandbox-vm/codex"
			warn "CODEX_HOME not set, using $codex_dir"
		fi
		mkdir -p "$codex_dir"
		codex_dir=$(realpath "$codex_dir")
		case "$codex_dir" in
		*,*) die "codex config dir may not contain commas: $codex_dir" ;;
		esac

		install_skill "$skill_source" "$codex_dir/.agents"

		qemu_args+=(
			-virtfs "local,path=$codex_dir,mount_tag=codex,security_model=none,id=fs${fs_id}"
		)
		fs_id=$((fs_id + 1))

		local agents_dir="$codex_dir/.agents"
		mkdir -p "$agents_dir"
		qemu_args+=(
			-virtfs "local,path=$agents_dir,mount_tag=agents,security_model=none,id=fs${fs_id}"
		)
		fs_id=$((fs_id + 1))
	fi

	info "---"
	info "Guest: $guest_arch | Accel: $accel | Display: $([ "$gui" = "true" ] && echo "gui" || echo "headless")"
	[ -n "$ssh_port" ] && info "SSH: ssh -p $ssh_port sandbox@localhost"
	info "---"

	CLEANUP_TMPDIR=$(mktemp -d)
	local qemu_log="$CLEANUP_TMPDIR/qemu.log"

	if [ "$gui" = "true" ]; then
		# run as child so the cleanup trap still fires on exit
		"${qemu_args[@]}" &
		QEMU_PID=$!
		wait "$QEMU_PID"
		return
	fi

	# headless: start qemu in background and auto-ssh
	"${qemu_args[@]}" &>"$qemu_log" &
	QEMU_PID=$!

	# generate throwaway ssh key (vm accepts any key)
	local ssh_key="$CLEANUP_TMPDIR/id_ed25519"
	ssh-keygen -t ed25519 -f "$ssh_key" -N "" -q

	info "waiting for vm (port $ssh_port)..."
	local attempts=0
	# poll for the real SSH banner, not just TCP accept: qemu's user-mode
	# networking accepts host-side the moment qemu starts, well before the
	# guest sshd is listening. reading the first bytes waits until the
	# guest really is speaking ssh
	while ! awaiting_ssh_banner "$ssh_port"; do
		attempts=$((attempts + 1))
		[ $attempts -gt 120 ] && die "vm did not become ready in 60s"
		kill -0 "$QEMU_PID" 2>/dev/null || die "qemu exited unexpectedly"
		sleep 0.5
	done
	VM_READY=true

	ssh -p "$ssh_port" -t \
		-i "$ssh_key" \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null \
		-o LogLevel=ERROR \
		sandbox@localhost
}

main "$@"

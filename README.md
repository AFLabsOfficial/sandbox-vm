# Sandbox VM

A disposable virtual machine with Claude Code pre-installed. Download an image,
run one command, and start coding with AI — no setup, no mess, no risk to your
host machine. Everything resets on shutdown.

**Choose your style:**

| | Headless | GUI |
|---|---|---|
| **Access** | SSH into the VM | Full Budgie desktop in a window |
| **Best for** | Terminal-comfortable developers | Visual workflows, less CLI experience |
| **Login** | SSH key authentication | Auto-login, no passwords |

**What's included:** Claude Code, git, docker, tmux, ripgrep, and more.
Mount your projects from the host, authenticate once, and you're ready to go.
Need something else? Install it with `nix profile add nixpkgs#<package>`.

## Prerequisites

Install QEMU on your host machine:

**macOS**
```sh
brew install qemu cdrtools
```

**Debian / Ubuntu**
```sh
sudo add-apt-repository ppa:brandonsnider/cdrtools
sudo apt-get update
sudo apt install cdrecord mkisofs cdda2wav
sudo apt install qemu-system-x86 qemu-kvm -y
```

## Quick start (GUI)

### 1. Get the image

Download `sandbox-gui-x86_64.qcow2` from
[dl.aflabs.org/iso](https://dl.aflabs.org/iso/).

### 2. Run

```sh
just run-gui ./sandbox-gui-x86_64.qcow2 \
  --mount ~/projects/my-app \
  --claude ~/.claude \
  --claude-json ~/.claude.json
```

A QEMU window opens and logs you straight into the desktop. Your projects
appear under `~/mnt/` and Claude Code is ready to use from the terminal.

## Quick start (headless)

### 1. Get the image

Download `sandbox-x86_64.qcow2` from
[dl.aflabs.org/iso](https://dl.aflabs.org/iso/).

### 2. Generate an SSH key (if needed)

```sh
ssh-keygen -t ed25519
```

### 3. Run

```sh
just run ./sandbox-x86_64.qcow2 \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --mount ~/projects/my-app \
  --claude ~/.claude \
  --claude-json ~/.claude.json
```

### 4. Connect

```sh
just ssh
```

## Run options

```
Usage: run.sh <image.qcow2> [options]

  --gui                  Launch with graphical display (default: headless)
  --ssh-key <key.pub>    SSH public key (repeatable)
  --seed-iso <iso>       Pre-built seed ISO (alternative to --ssh-key)
  --mount <path>         Mount host directory into VM (repeatable)
  --claude <path>        Mount claude config dir writable into VM
  --claude-json <path>   Pass .claude.json config into VM
  --arch <arch>          Guest architecture (default: host arch)
  --memory <size>        VM memory (default: 8G)
  --cpus <n>             VM CPUs (default: 4)
  --ssh-port <port>      SSH port forward (default: 2222)
```

### Mounting projects

Each `--mount` shares a host directory into the VM at `~/mnt/<dirname>`:

```sh
just run-gui ./sandbox-gui-x86_64.qcow2 \
  --mount ~/projects/frontend \
  --mount ~/projects/backend
```

Inside the VM:
```
~/mnt/frontend/
~/mnt/backend/
```

### Claude Code

Pass `--claude ~/.claude` to mount your claude config writable into the VM.
Pass `--claude-json ~/.claude.json` to inject your auth config.
Claude Code is pre-installed and will pick up your auth automatically.

## Installing additional tools

Need a language runtime or tool that isn't pre-installed? Install it inside
the VM:

```sh
nix profile add nixpkgs#nodejs nixpkgs#pnpm
```

Packages persist across terminal sessions until the VM shuts down.
Use `nix search nixpkgs <name>` to find packages.

### Common language stacks

| Stack   | Install command                                            |
|---------|------------------------------------------------------------|
| Node.js | `nix profile add nixpkgs#nodejs nixpkgs#pnpm`             |
| Python  | `nix profile add nixpkgs#python3 nixpkgs#uv`              |
| Go      | `nix profile add nixpkgs#go nixpkgs#gopls`                |
| Rust    | `nix profile add nixpkgs#cargo nixpkgs#rustc`             |
| Java    | `nix profile add nixpkgs#jdk nixpkgs#gradle`              |

## Building from source

If you have nix installed, you can build images locally instead of downloading:

```sh
just build x86_64        # headless
just build-gui x86_64    # GUI
```

Both support `x86_64` and `aarch64` architectures.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

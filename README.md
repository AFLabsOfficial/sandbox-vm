# Sandbox VM

A disposable virtual machine with Claude Code pre-installed. Run one command
and start coding with AI — no setup, no mess, no risk to your host machine.
Everything resets on shutdown.

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

**macOS**
```sh
brew install just qemu cdrtools curl
```

**Debian / Ubuntu**
```sh
# x86_64 hosts
sudo apt install just qemu-system-x86 qemu-kvm genisoimage curl -y

# aarch64 hosts
sudo apt install just qemu-system-arm qemu-efi-aarch64 genisoimage curl -y
```

Images are built for **x86_64** (Intel/AMD) and **aarch64** (Apple Silicon,
ARM Linux). The correct architecture is auto-detected. Apple Silicon Macs run
the aarch64 image natively with hardware acceleration; the x86_64 image works
too but runs under emulation (much slower).

## Quick start

Pulls the latest image and launches it:

```sh
# Headless (generate a key first with ssh-keygen -t ed25519 if needed)
just run-headless --ssh-key ~/.ssh/id_ed25519.pub --mount ~/projects
just ssh  # from a different terminal

# GUI
just run-gui --mount ~/projects --claude ~/.claude --claude-json ~/.claude.json
```

## Images

Images are hosted at [dl.aflabs.org/iso](https://dl.aflabs.org/iso/) and
managed with the `pull` and `list-images` commands:

```sh
just pull headless                                # download latest
just pull headless --version fe3265e              # specific version
just list-images headless                         # list available versions
```

Downloaded images are cached in `~/.cache/sandbox-vm/` (or
`$XDG_CACHE_HOME/sandbox-vm/` if set).

To run a local image directly:

```sh
just run-image-headless ./sandbox-headless-x86_64.qcow2 --ssh-key ~/.ssh/id_ed25519.pub
just run-image-gui ./sandbox-gui-x86_64.qcow2 --mount ~/projects
```

## Run options

```
  --ssh-key <key.pub>    SSH public key (repeatable)
  --seed-iso <iso>       Pre-built seed ISO (alternative to --ssh-key)
  --mount <path>         Mount host directory into VM (repeatable)
  --claude <path>        Mount claude config dir writable into VM
  --claude-json <path>   Mount .claude.json writable into VM
  --arch <arch>          Guest architecture (default: host arch)
  --memory <size>        VM memory (default: 8G)
  --cpus <n>             VM CPUs (default: 4)
  --ssh-port <port>      SSH port forward (default: 2222)
```

### Mounting projects

Each `--mount` shares a host directory into the VM at `~/mnt/<dirname>`:

```sh
just run-gui \
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
Pass `--claude-json ~/.claude.json` to mount your auth config writable into the VM.
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
just build-headless x86_64
just build-gui x86_64
```

Both support `x86_64` and `aarch64` architectures.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

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
# headless (generate a key first with ssh-keygen -t ed25519 if needed)
just run-headless --ssh-key ~/.ssh/id_ed25519.pub --claude --mount /path/to/project
just ssh  # from a different terminal

# gui
just run-gui --claude --mount /path/to/project
```

## SSH

```sh
just ssh                              # default port 2222
just ssh 2222 -L 8080:localhost:8080  # port forward
```

> **Note:** The `sandbox` user has password `sandbox` as a fallback for debugging.

## Run options

```
  --ssh-key <key.pub>    SSH public key (repeatable)
  --seed-iso <iso>       Pre-built seed ISO (alternative to --ssh-key)
  --mount <path>         Mount host directory into VM (repeatable)
  --claude               Mount claude config dir (uses CLAUDE_CONFIG_DIR or ~/.config/sandbox-vm/claude)
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

Pass `--claude` to mount your claude config dir writable into the VM. Uses
`CLAUDE_CONFIG_DIR` if set, otherwise falls back to `~/.config/sandbox-vm/claude`.
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

## Images

Images are hosted at [dl.aflabs.org/iso](https://dl.aflabs.org/iso/) and
managed with the `pull` and `list-images` commands:

```sh
just pull headless                    # download latest
just pull headless --version v0.1.0   # specific version
just list-images headless             # list available versions
```

Downloaded images are cached in `~/.cache/sandbox-vm/` (or
`$XDG_CACHE_HOME/sandbox-vm/` if set).

To run a local image directly:

```sh
just run-image-headless ./sandbox-headless-x86_64-v0.1.0.qcow2 --ssh-key ~/.ssh/id_ed25519.pub
just run-image-gui ./sandbox-gui-x86_64-v0.1.0.qcow2 --mount ~/projects
```

## Building from source

Requires [nix](https://nixos.org/download/). Works on NixOS, any Linux with
nix, macOS (with a remote Linux builder), or inside Docker.

```sh
just build-headless x86_64        # or aarch64
just build-gui x86_64

# or directly with nix
nix build .#packages.x86_64-linux.sandbox-headless
nix build .#packages.aarch64-linux.sandbox-gui
```

Built images are GPG-signed and placed in `dist/`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

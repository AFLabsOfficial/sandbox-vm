# Sandbox VM

A disposable virtual machine with Claude Code pre-installed. Run one command
and start coding with AI — no setup, no mess, no risk to your host machine.
Everything resets on shutdown.

**Choose your style:**

| | Headless | GUI |
|---|---|---|
| **Access** | Auto-connects via SSH | Full GNOME desktop in a window |
| **Best for** | Terminal-comfortable developers | Visual workflows, less CLI experience |
| **Login** | Automatic (any SSH key accepted) | Auto-login, no passwords |

**What's included:** Claude Code, OpenAI Codex, git, docker, tmux, ripgrep, and more.
Mount your projects from the host, authenticate once, and you're ready to go.
Need something else? Install it with `nix profile add nixpkgs#<package>`.

## Prerequisites

**macOS**
```sh
brew install just qemu curl gnupg coreutils bash
```
`coreutils` provides `gtimeout`, which `run.sh` needs to bound its SSH-readiness
probe. `bash` is required because the scripts use features unavailable in the
bash 3 that ships with macOS.

**Debian / Ubuntu**
```sh
# x86_64 hosts
sudo apt install just qemu-system-x86 qemu-kvm curl gnupg -y

# aarch64 hosts
sudo apt install just qemu-system-arm qemu-efi-aarch64 curl gnupg -y
```

**WSL**

After installing the packages above, add your user to the `kvm` group so the
VM can use hardware acceleration:

```sh
sudo usermod -aG kvm $USER
```

Log out and back in for the group change to take effect.

`gnupg` is optional but strongly recommended; without it, `pull` falls back to
sha256-only, which does not authenticate against a network attacker.

Images are built for **x86_64** (Intel/AMD) and **aarch64** (Apple Silicon,
ARM Linux). The correct architecture is auto-detected. Apple Silicon Macs run
the aarch64 image natively with hardware acceleration; the x86_64 image works
too but runs under emulation (much slower).

## Quick start

Add an alias to your shell rc (`~/.zshrc`, `~/.bashrc`, etc.) so you can
launch a VM from any project directory. Replace `/path/to/` with the actual
path to your clone of this repo:

```sh
alias sandbox-vm="/path/to/sandbox-vm.nix/scripts/run.sh"
```

Reload your shell (or `source` the rc file), then:

```sh
# headless (auto-connects via ssh)
sandbox-vm --headless --mount .

# gui
sandbox-vm --gui --mount .
```

The latest image is pulled automatically on first launch.

If you always use the same variant, bake it into the alias:

```sh
alias sandbox-vm="/path/to/sandbox-vm.nix/scripts/run.sh --headless"
# then: sandbox-vm --mount .
```

### Alternative: `just` commands

The repo ships `just` recipes for running from a cloned checkout. These are
kept for convenience but the alias above is preferred:

```sh
just run-headless --mount /path/to/project
just run-gui --mount /path/to/project
```

## SSH

Headless mode automatically connects via SSH. To open additional sessions:

```sh
just ssh                                # default port 22022
just ssh 22022 -L 8080:localhost:8080   # port forward
```

> **Note:** The `sandbox` user has password `sandbox` for console access (SSH
> disables password auth).

## Run options

```
  --mount <path>         Mount host directory into VM (repeatable)
  --no-claude            Skip mounting claude config dir
  --no-codex             Skip mounting codex config dir
  --no-pull              Use latest cached image instead of downloading
  --arch <arch>          Guest architecture (default: host arch)
  --disk-size <size>     Resize guest disk (e.g. 50G)
  --memory <size>        VM memory (default: 4G)
  --cpus <n>             VM CPUs (default: 2)
  --ssh-port <port>      SSH port forward (default: auto from 22022)
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

Claude config is mounted by default into the VM (writable). Uses
`CLAUDE_CONFIG_DIR` if set, otherwise falls back to `~/.config/sandbox-vm/claude`.
Claude Code is pre-installed and will pick up your auth automatically.
Pass `--no-claude` to skip mounting.

This repo includes a `/sandbox-vm` skill for Claude Code. To make it available
globally, copy it to your personal skills directory:

```sh
mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.config/sandbox-vm/claude}"/skills/sandbox-vm
cp -r .claude/skills/sandbox-vm/* "${CLAUDE_CONFIG_DIR:-$HOME/.config/sandbox-vm/claude}"/skills/sandbox-vm/
```

Then run `/sandbox-vm` inside the VM to give Claude context about the environment.

### Codex

Codex config is mounted the same way. Uses `CODEX_HOME` if set, otherwise
falls back to `~/.config/sandbox-vm/codex`. Codex is pre-installed and will
pick up your auth automatically. Pass `--no-codex` to skip mounting.

## Installing additional tools

Need a language runtime or tool that isn't pre-installed? Install it inside
the VM:

```sh
nix profile add nixpkgs#nodejs nixpkgs#pnpm
```

Packages persist across terminal sessions until the VM shuts down.
Use `nix search nixpkgs <name>` to find packages.

The default image includes 30G of disk space. For heavier toolchains, pass
`--disk-size` to grow the guest disk at launch:

```sh
just run-headless --disk-size 50G
```

This creates a temporary overlay — the cached image is not modified and the
extra space costs nothing on the host until the guest actually writes to it.

### Common language stacks

| Stack   | Install command                                            |
|---------|------------------------------------------------------------|
| Node.js | `nix profile add nixpkgs#nodejs nixpkgs#pnpm`             |
| Python  | `nix profile add nixpkgs#python3 nixpkgs#uv`              |
| Go      | `nix profile add nixpkgs#go nixpkgs#gopls`                |
| Rust    | `nix profile add nixpkgs#cargo nixpkgs#rustc`             |
| Java    | `nix profile add nixpkgs#jdk nixpkgs#gradle`              |

## Images

Images are hosted at [dl.aflabs.org/iso](https://dl.aflabs.org/iso/).
`just run-headless` / `just run-gui` **auto-pull the latest image** on launch;
pass `--no-pull` to stay fully offline and use the latest cached image.

For explicit control, use the `pull` and `list-images` commands:

```sh
just pull headless                    # download latest
just pull headless --version v0.4.0   # specific version
just list-images headless             # list available versions
```

Downloaded images are cached in `~/.cache/sandbox-vm/` (or
`$XDG_CACHE_HOME/sandbox-vm/` if set). SHA256 checksums are GPG-signed; the
public keys are in [`KEYS`](KEYS). `pull` always verifies sha256 and verifies
the signature when `gpg` is installed. Cached images are re-verified on every
launch; if the server is unreachable, `pull` transparently falls back to the
cached image (still re-verified).

To run a local image directly:

```sh
just run-headless ./sandbox-headless-x86_64-v0.4.0.qcow2
just run-gui ./sandbox-gui-x86_64-v0.4.0.qcow2 --mount ~/projects
```

## Building from source

```sh
just build --headless                  # headless, host arch, requires nix
just build --gui                       # gui variant
just build --headless --arch aarch64   # cross-build
just build --headless --docker         # via docker (Linux only, no nix required)
just build --headless --sign           # sign the image after building
```

Built images are placed in `dist/`. The `--docker` path requires Linux with
KVM (`/dev/kvm`) and does not work on macOS. `--docker` cannot cross-build;
use nix (with a remote builder if needed) to target a different architecture.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

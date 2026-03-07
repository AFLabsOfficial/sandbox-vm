# sandbox-vm.nix

Ephemeral NixOS virtual machine for AI-assisted development. Boots a disposable
VM with Claude Code pre-installed, mounts your projects and claude config from
the host, and tears down cleanly on exit. The disk runs in snapshot mode — all
changes are discarded on shutdown, so every boot starts from a clean state.

- Mount host project directories into the VM (supports multiple mounts)
- Mount `.claude` config for automatic Claude Code authentication
- `claude-code`, `git` and `docker` available out of the box
- NixOS-based — install any additional tool with `nix profile add`
- Supports x86_64 and aarch64 guests on Linux (KVM) and macOS (HVF)

## Prerequisites

Install QEMU and ISO tools on your host machine:

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

**NixOS / nix**
```sh
nix develop   # provides qemu and cdrtools
```

## Quick start

### 1. Get the image

Download a pre-built qcow2 from
[dl.aflabs.org/iso](https://dl.aflabs.org/iso/), or build locally with nix:

```sh
just build x86_64    # or aarch64
```

### 2. Generate an SSH key (if needed)

The VM uses SSH key authentication. If you don't have a key:

```sh
ssh-keygen -t ed25519
```

### 3. Run the VM

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
# or with a custom port
just ssh 2223
```

Under the hood this runs
`ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null sandbox@localhost`.
The flags are needed because the VM generates a new host key on every boot —
without them SSH would report a key conflict in `~/.ssh/known_hosts`.

## Run script options

```
Usage: run.sh <image.qcow2> [options]

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
# mount multiple projects
just run ./sandbox.qcow2 \
  --ssh-key ~/.ssh/id_ed25519.pub \
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

## Nix package manager

The VM runs NixOS. You don't need to know nix to use it, but it helps for
installing additional tools.

### Install packages

```sh
nix profile add nixpkgs#nodejs nixpkgs#pnpm
```

Packages installed with `nix profile` persist across SSH sessions and
tmux windows. Use `nix search nixpkgs <name>` to find packages.

### Common language stacks

| Stack   | Packages                                         |
|---------|--------------------------------------------------|
| Node.js | `nodejs`, `pnpm`, `yarn`                         |
| Python  | `python3`, `uv`                                  |
| Go      | `go`, `gopls`                                    |
| Rust    | `cargo`, `rustc`, `rustfmt`, `clippy`            |
| Java    | `jdk`, `gradle`, `maven`                         |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

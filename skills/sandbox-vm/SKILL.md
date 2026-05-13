---
name: sandbox-vm
description: Context for working inside the sandbox VM. Covers what survives shutdown, how to install packages on NixOS, and where the host's files and tool configs live.
disable-model-invocation: true
---

# Sandbox VM

You are inside a disposable NixOS virtual machine. The root disk is a temporary
overlay over a baseline image — every shutdown wipes it clean. Be bold:
experiments, broken configs, `rm -rf /`-grade mistakes inside the VM cannot
reach the host.

## What survives shutdown

Only two things:

- **`~/mnt/<name>/`** — 9p mounts of host directories the user passed via
  `--mount`. Writes here land on the host filesystem immediately. Treat these
  paths as if you were editing on the host, because you are.
- **`~/.config/claude/` and `~/.codex/`** — the host's tool config dirs,
  mounted in. Sessions, memories, settings, and skills round-trip to the host.

Everything else (packages, files outside `~/mnt`, services, shell history,
sudo edits) is gone on next boot.

## Installing packages

This is NixOS — `apt`, `dnf`, `brew`, and `pip install --user` will not work.
Use Nix profiles:

```sh
nix profile add nixpkgs#nodejs nixpkgs#pnpm    # install
nix search nixpkgs hyperfine                   # find
nix profile list                               # show installed
nix profile remove nodejs                      # uninstall
```

For one-off use without adding to `$PATH` permanently:

```sh
nix shell nixpkgs#hyperfine -c hyperfine 'sleep 0.1'
```

Installed packages disappear at shutdown. If the user reinstalls the same
toolchain on every boot, suggest baking it into the image (the repo's
`flake.nix`) instead.

## Pre-installed

`claude-code`, `codex`, `git`, `docker`, `tmux`, `just`,
`neovim` (`vim` / `vi`), `ripgrep` (`rg`), `fd`, `jq`, `fzf`.

## Working with host files

Only directories the user explicitly mounted are reachable, at
`~/mnt/<basename>`. If the user references a path that is not under `~/mnt`,
they need to relaunch the VM with `--mount /that/path` — point this out
rather than trying to find another way in.

## Disk space

The base disk is 30G. If a build fills it, the user can relaunch with
`--disk-size 50G` (or larger). The overlay is sparse, so a bigger guest disk
costs nothing on the host until you actually write to it.

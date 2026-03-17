---
name: sandbox-vm
description: Use when running inside the sandbox VM. Provides context about the NixOS environment, available tools, and how to install packages.
disable-model-invocation: true
---

# Sandbox VM environment

You are running inside a **disposable NixOS virtual machine**. Everything resets
on shutdown — there is no persistent state. Be bold; you cannot break anything
permanently.

## Pre-installed tools

claude-code, git, neovim (aliased to `vim`/`vi`), tmux, ripgrep (`rg`), fd, jq,
fzf, just, docker.

## Installing packages

Use `nix profile add nixpkgs#<package>` to install additional packages.
Use `nix search nixpkgs <name>` to find packages.

## Mounted projects

Host projects are mounted at `~/mnt/<dirname>`. These are shared directories —
changes here persist on the host even after the VM shuts down.

## Claude config

The host's Claude config directory is mounted into the VM. Previous sessions,
settings, and memories are available — you can search and resume past
conversations.

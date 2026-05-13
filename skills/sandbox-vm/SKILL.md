---
name: sandbox-vm
description: Use at the start of any session running inside the sandbox VM. Signals you are inside the VM — env var SANDBOX_VM=1, file /etc/sandbox-vm-release, or hostname sandbox. Covers the disposable NixOS environment, nix profile installs, docker, host directories mounted at ~/mnt/<name>, and the $SANDBOX_VM_STATE convention for routing tool-managed state (venvs, node_modules, target/, .gradle/, test/lint caches) out of host-mounted projects.
---

# Sandbox VM

You are inside a disposable NixOS micro-VM. The root disk is a temporary
overlay over a baseline image; every shutdown wipes it. The host machine is
unreachable except through the directories the user explicitly mounted.

## Two filesystems, one rule

- **`~/mnt/<name>/`** — 9p mounts of host directories. Writes here land on the
  host immediately. Treat these paths as if you were editing on the host,
  because you are.
- **everything else** — guest-local, ephemeral, gone on next boot.

The rule: never write tool-managed state into `~/mnt/<name>`. That covers
the obvious cases — `.venv`, `node_modules`, `target/`, `.gradle/` — and
the small ones a tool auto-creates next to source: `.pytest_cache`,
`.ruff_cache`, `.mypy_cache`, `.coverage`, `.next/`, `.turbo/`. All of it
was built for the host's arch and toolchain, will not work in the guest,
and overwriting it clobbers the host's setup. Redirect to guest-local
paths instead.

uid mismatches between host and guest can also cause writes under
`~/mnt/<name>/` to fail with EACCES or ENOENT even where reads succeed —
if a write inexplicably errors on a host-mounted path, that's why.

## Guest-local state: `$SANDBOX_VM_STATE`

`$SANDBOX_VM_STATE` (default `$HOME/.local/state/sandbox-vm`) is the root for
everything you build inside the VM. Slug subdirectories by the host mount
basename (`~/mnt/foo` → `$SANDBOX_VM_STATE/foo/`). If two mounts share a
basename, suffix one of them by hand and tell the user.

Most language tools accept an env var that moves per-project state outside
the project tree. Set it once and keep working. See
[`references/language-stacks.md`](references/language-stacks.md) for the
per-tool table — `UV_PROJECT_ENVIRONMENT`, `POETRY_VIRTUALENVS_PATH`,
`CARGO_TARGET_DIR`, `GRADLE_USER_HOME`, etc.

A handful of stacks expect their dependency or build dir next to the source
and cannot be redirected by env var — Node (`node_modules/`), PHP
(`vendor/`), .NET (`bin/`, `obj/`), Bazel (`bazel-*` symlinks). For these,
the only working approach is to delete the host's copy and reinstall in the
guest. **Confirm with the user first** — the reinstall replaces what the
host built and the host will need to reinstall on its next session. Details
and suggested phrasing in `references/language-stacks.md`.

## Docker

Docker is pre-installed; the daemon starts with the VM. Images and volumes
live in `/var/lib/docker` on guest disk and are wiped on shutdown.

If a project's dev or deploy flow expects docker, run it from the VM — there
is no need to bounce back to the host. Keep guest-only configuration (env
files, compose overrides, build args) under
`$SANDBOX_VM_STATE/<slug>/docker/`, not in the project root:

```sh
docker compose --env-file $SANDBOX_VM_STATE/<slug>/docker/.env up
docker compose \
    -f docker-compose.yml \
    -f $SANDBOX_VM_STATE/<slug>/docker/override.yml up
```

Treat bind-mount sources the same way: if a compose service needs persistent
data, point the bind at `$SANDBOX_VM_STATE/<slug>/…`, never at a relative
path that lands in `~/mnt/`.

When you only need a service dependency for tests (postgres, redis, kafka,
etc.) and the project ships its own `docker-compose.yaml`, prefer
`docker compose -f <file> up -d <service>` over hand-rolling `docker run`
— you pick up the project's expected image, env, healthchecks, and network
naming for free. Pass `--env-file <project>/.env` explicitly when the
compose file references variables: `docker compose -f <path>` does **not**
auto-load a sibling `.env` for interpolation, so containers will start
with empty variables and die confusingly (e.g. `POSTGRES_PASSWORD missing`).

If the project's app code resolves dependencies by their compose service
name (`DB_HOST=db`, `REDIS_HOST=redis`), spinning up the services from the
guest is not enough — those names only resolve *inside* the compose
network. Either run the test command inside the app's own service so it
inherits the network and any `env_file:`-loaded variables:

```sh
docker compose -f <file> --env-file <project>/.env \
    run --rm <app-service> <test-cmd>
```

…or expose the relevant ports in the compose file and override the host
env vars (`DB_HOST=127.0.0.1`, etc.) before invoking tests natively. Note
that native test runners do **not** auto-load `.env` the way compose does;
`set -a; source .env; set +a` before invocation, or the run will fail with
empty/missing variables.

## Pre-installed

`claude-code`, `codex`, `git`, `docker`, `tmux`, `just`,
`neovim` (`vim` / `vi`), `ripgrep` (`rg`), `fd`, `jq`, `fzf`.

**Not preinstalled** — every language runtime and package manager. Don't
probe `which python` / `which node` / `which cargo` to discover the
environment; assume nothing is there until you `nix profile add` it. Common
adds: `nixpkgs#{python313,python314,uv,nodejs,pnpm,go,rustc,cargo,gcc,jdk,gradle,maven,ruby,bundler,elixir,ghc,cabal-install,php}`.

## Installing packages

NixOS — `apt`, `brew`, `pip install --user` do not apply.

```sh
nix profile add nixpkgs#nodejs nixpkgs#pnpm   # persistent for this boot
nix search nixpkgs hyperfine                  # find
nix shell nixpkgs#hyperfine -c hyperfine ...  # one-shot, no profile entry
```

Profile installs vanish at shutdown. If the same toolchain is needed every
boot, suggest the user bake it into `flake.nix` rather than reinstalling.

Nixpkgs attribute paths sometimes diverge from upstream names
(`python3Packages.requests`, not `requests`); if `nixpkgs#foo` fails, run
`nix search nixpkgs foo` to find the real attribute.

## When the host can do it faster

The default is to run things in the guest. Defer to the host only in the
extreme cases:

- The work duplicates state the host already has and the guest would
  re-fetch it from scratch — typically `nixos-rebuild` / `nix flake check`
  on the user's own NixOS config, where the host's Nix store is warm and
  the guest pull is gigabytes.
- The work needs hardware the VM does not have (GPU, native macOS toolchain).
- The work needs host-only secrets — the host's SSH agent, cloud credential
  files mounted only on the host, etc.

Cargo / Gradle / npm / pytest etc. run in the guest by default. "Builds
might be slow" is not a reason to defer; only "the guest would have to
download or rebuild gigabytes the host already has" is.

Phrase deferrals so the host is clearly the better tool, not an escape
hatch:

> This needs most of nixpkgs and your host has it warm. Try
> `nixos-rebuild dry-build --flake .` on the host and paste the output.

## Autonomy

The VM is disposable. Do not ask before installing packages, creating or
deleting files under `$HOME` or `$SANDBOX_VM_STATE`, starting services, or
running destructive commands inside the guest. Permission prompts for these
actions are noise — the sandbox already grants them.

Two boundaries remain:

- `~/mnt/<name>/` is host-shared. Edits there are edits on the host. Keep
  them scoped to what was asked, and never use it for tool state. The one
  case where touching it is unavoidable (Node / PHP / .NET / Bazel
  reinstalls) requires explicit confirmation — see above.
- `rm -rf /` and `rm -rf ~` still prompt as a circuit-breaker even with
  permissions bypassed. Do not try to work around it.

## Host config mounts

`$CLAUDE_CONFIG_DIR` and `$CODEX_HOME` are mounted from the host. Sessions,
memories, settings, and skills round-trip — edits here are the host's edits.

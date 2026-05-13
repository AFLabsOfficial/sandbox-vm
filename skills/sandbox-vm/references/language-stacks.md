# Language stacks

Per-tool guidance for routing per-project state out of `~/mnt/<slug>/` and
into `$SANDBOX_VM_STATE/<slug>/`. The rule from `SKILL.md` applies: never
write tool-managed state into a host-mounted directory.

## Python quickstart (uv)

The canonical copy-paste recipe — install the runtime and uv together,
then always pass `--python`:

```sh
nix profile add nixpkgs#python314 nixpkgs#uv
export UV_PROJECT_ENVIRONMENT=$SANDBOX_VM_STATE/<slug>/.venv
uv sync --python "$(which python3.14)"
```

`--python` is non-negotiable. If uv doesn't see a system Python it likes,
it autodownloads CPython from python-build-standalone, and those binaries
fail on NixOS with `stub-ld` (see the NixOS callout below). The error
message recommends a fix that does not actually fix this — it points at
`nix.dev/permalink/stub-ld`, which doesn't know about your nix-installed
python. Skip the lookup and pass `--python "$(which python3.14)"`.

Tools that ship as prebuilt binaries inside a PyPI package — `ruff`, `ty`,
some `polars` / `orjson` wheels — fail with the same `stub-ld` error when
installed through pip / `uv pip`. Install them via `nix profile add
nixpkgs#<tool>` instead and call the nix-installed binary; pip-installed
tools that are pure Python (pytest, mypy, coverage) work fine.

## Stacks redirectable by env var

Set the env var once at the start of the session (or in a project-local
`.envrc`) and the tool will keep all its state guest-local.

**Set every redirect this project needs upfront, before the first tool
invocation.** Tools write caches lazily — a single `pytest`, `cargo build`,
or `gradle test` will leave a `.pytest_cache/`, `target/`, or `.gradle/`
next to the source if the env var is exported after the fact. Partial
setup is worse than full setup: you end up half-clean, half-not.

| Tool        | Env var / flag                                                 | Value                                              |
|-------------|----------------------------------------------------------------|----------------------------------------------------|
| **uv**      | `UV_PROJECT_ENVIRONMENT` (see NixOS callout for the Python interpreter) | `$SANDBOX_VM_STATE/<slug>/.venv`                   |
| **pip / venv** | (create venv at path, activate it)                          | `$SANDBOX_VM_STATE/<slug>/.venv`                   |
| **poetry**  | `POETRY_VIRTUALENVS_IN_PROJECT=false`, `POETRY_VIRTUALENVS_PATH` | `$SANDBOX_VM_STATE/<slug>/poetry`                  |
| **pipx**    | `PIPX_HOME`, `PIPX_BIN_DIR` (defaults are already guest-local) | `$HOME/.local/share/pipx`, `$HOME/.local/bin`      |
| **cargo**   | `CARGO_TARGET_DIR` (see Rust linker note below)                | `$SANDBOX_VM_STATE/<slug>/cargo-target`            |
| **rustup**  | `RUSTUP_HOME`, `CARGO_HOME`                                   | `$HOME/.rustup`, `$HOME/.cargo` (defaults are guest-local) |
| **go**      | `GOPATH`, `GOMODCACHE`                                        | `$HOME/go` (default is guest-local; only override if the project sets `GOPATH` under `~/mnt`) |
| **gradle**  | `GRADLE_USER_HOME` **and** `--project-cache-dir` (both are needed — see Gradle note below) | `$SANDBOX_VM_STATE/<slug>/gradle`, `$SANDBOX_VM_STATE/<slug>/gradle-project-cache` |
| **maven**   | `MAVEN_OPTS=-Dmaven.repo.local=...`                           | `$SANDBOX_VM_STATE/<slug>/m2`                      |
| **ruby / bundler** | `BUNDLE_PATH`                                          | `$SANDBOX_VM_STATE/<slug>/bundle`                  |
| **elixir / mix** | `MIX_BUILD_PATH`, `MIX_DEPS_PATH`                        | `$SANDBOX_VM_STATE/<slug>/{build,deps}`            |
| **haskell / cabal** | `--builddir` flag                                     | `$SANDBOX_VM_STATE/<slug>/cabal-build`             |

When a stack is not listed, the pattern is the same: find the env var or
flag that moves per-project state outside the project tree, point it at
`$SANDBOX_VM_STATE/<slug>/`.

### NixOS + tool-bundled prebuilts

Tools that auto-download their own prebuilt runtime — `uv` pulling CPython
from python-build-standalone, `mise`, `asdf`, `rustup` toolchains, anything
fetching from generic-glibc release tarballs — fail on NixOS with `stub-ld`
errors because the binaries are dynamically linked against paths that do
not exist in the Nix store.

The fix is to install the runtime via `nix profile add` and force the tool
to use it. Don't rely on `$PATH` discovery alone — order-of-install
matters (uv installed before the python is on `$PATH` will start
downloading on first invocation), and `requires-python` mismatches send
uv straight to the autodownload path. Pass `--python` explicitly so the
choice is deterministic and the autodownload path is never reached:

```sh
nix profile add nixpkgs#python314
uv sync --python "$(which python3.14)"
```

For a session-wide switch instead of a per-invocation flag,
`export UV_PYTHON_PREFERENCE=only-system` makes uv refuse downloaded
interpreters entirely.

Same shape for `rustup` (`rustup toolchain link <name> $(dirname $(which rustc))`
after `nix profile add nixpkgs#rustc`), `mise` (`mise use system`), and any
other version manager that defaults to fetching its own binaries. Prefer
nixpkgs runtimes over tool-bundled prebuilts; the autofetch path will not
work here.

### Rust linker

`nix profile add nixpkgs#cargo nixpkgs#rustc` is **not** enough to build any
crate with proc-macros or build scripts — cargo invokes `cc` / `ld` and
needs a C toolchain on `$PATH`. Add one:

```sh
nix profile add nixpkgs#gcc
cargo build       # now finds cc / ld and links cleanly
```

### Gradle

`GRADLE_USER_HOME` redirects the global Gradle home (daemon, distributions,
artifact caches), but Gradle also writes a per-project `.gradle/` directory
for project lock files and build-cache metadata. That dir lands next to the
sources unless you also pass `--project-cache-dir`:

```sh
export GRADLE_USER_HOME="$SANDBOX_VM_STATE/<slug>/gradle"
gradle --project-cache-dir "$SANDBOX_VM_STATE/<slug>/gradle-project-cache" build
```

If you forget the flag, expect a stray `.gradle/` to appear in the project
tree (which violates the no-state-in-mnt rule).

### Tool caches

A separate class of files tools auto-create next to source — small, fast
to rebuild, easy to forget. Same rule applies: redirect them under
`$SANDBOX_VM_STATE/<slug>/`. The ones with a clean env var:

| Tool           | Redirect                                                        |
|----------------|-----------------------------------------------------------------|
| **pytest**     | `PYTEST_ADDOPTS='-o cache_dir=$SANDBOX_VM_STATE/<slug>/pytest_cache'` (or `[tool.pytest.ini_options].cache_dir` in pyproject.toml) |
| **ruff**       | `RUFF_CACHE_DIR=$SANDBOX_VM_STATE/<slug>/ruff_cache`             |
| **mypy**       | `MYPY_CACHE_DIR=$SANDBOX_VM_STATE/<slug>/mypy_cache`             |
| **coverage.py**| `COVERAGE_FILE=$SANDBOX_VM_STATE/<slug>/coverage.db` (a file, not a dir) |
| **CPython bytecode** | `PYTHONPYCACHEPREFIX=$SANDBOX_VM_STATE/<slug>/pycache` — every `__pycache__` Python would write goes under this prefix instead |
| **Turbo (Node)** | `TURBO_CACHE_DIR`                                             |
| **Parcel (Node)** | `PARCEL_CACHE_DIR` or `--cache-dir`                          |
| **Jest**       | `--cacheDirectory <path>` or `cacheDirectory` in `jest.config.js` |
| **ESLint**     | `--cache-location <path>` (no env var)                          |
| **Vite**       | `cacheDir` in `vite.config.js` (no env var)                     |
| **Next.js**    | `distDir` in `next.config.js` (no env var; `.next/` is awkward to relocate) |

If a tool writes to `.something/` and isn't listed, check its docs for a
cache-dir flag or env var — most have one. Don't let small caches slip
through; on a host-mounted project they will eventually trip a write-perm
error from uid mismatch or stale ownership.

### `nix profile add` conflicts

Some package pairs ship the same binary and refuse to coexist in a single
profile — `ruby` and `bundler` both provide `bin/bundle`, for example.
`nix profile add` prints the resolution hint:

```
nix profile add flake:nixpkgs#legacyPackages.x86_64-linux.bundler --priority 4
```

Follow the hint, or install the conflicting package separately with
`--priority` set lower than the existing one.

## Stacks that require state in-project

A few tools expect their dependency or build directory next to the source
and cannot be redirected:

- **Node** (`npm` / `pnpm` / `yarn`) — `node_modules/`. Module resolution
  walks up from `__dirname` looking for it; `NODE_PATH` is deprecated and
  ignored by most build systems.
- **PHP** (`composer`) — `vendor/`. Same shape as `node_modules`.
- **.NET** (`dotnet`) — `bin/`, `obj/`. Redirection via
  `BaseIntermediateOutputPath` / `BaseOutputPath` is per-project MSBuild
  plumbing, not a single env var.
- **Bazel** — `bazel-*` workspace symlinks. `--output_base` moves the heavy
  storage but the symlinks still appear in the workspace.

For these, the only working approach is to delete the host's copy and
reinstall in the guest. **Confirm with the user before doing this.** The
reinstall replaces what the host built, and the host will need to reinstall
on its next session.

Suggested confirmation phrasing:

> The host's `node_modules` for `foo` was built for the host machine and
> won't work in the guest. Reinstalling here will replace it; the host will
> need to reinstall on its next session. Proceed?

Confirm once per project per session — follow-up installs in the same
project (e.g. adding a dependency after the initial install) do not need
to ask again.

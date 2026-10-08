# Contributing

## Development

Requires nix with flakes enabled.

```sh
# enter dev shell (provides pre-commit, statix, qemu)
nix develop

# or with direnv
direnv allow

# format
nix fmt

# lint
statix check

# build image
just build x86_64
just build aarch64
```

## Releasing

A release is a branch with one commit per bump and one for the version string,
merged into `main` and then tagged, which is what triggers the image builds.

Run the `prepare-release-mr` job to create it: start a manual (web) pipeline on
`main` and play the job in the `release` stage. It bumps `flake.lock`, every
`packages/*/update.sh`, and the version in `flake.nix`, then opens the merge
request. The job fails if nothing changed, or if the version is already tagged.
The version gets a patch bump unless the pipeline sets `RELEASE_BUMP=minor` or
`major`; that is a deliberate choice, not derived from commit types.

Before committing the lockfile bump, the job dry-runs the image for both
architectures against the new lock. If that would mean building a package
cache.nixos.org does not have (other than the packaged tools, which every bump
rebuilds), the new nixpkgs most likely has a package failing on Hydra, so the
lockfile is left out of the release and the merge request description names the
blockers. The tool bumps still go out. `nixos-unstable` only waits for Hydra's
`tested` job, not for every package, which is how a broken contour reached it.
Set `RELEASE_LOCK` on the pipeline to override: `force` always takes the new
lock, `skip` never touches it, `auto` (the default) gates it.

The merge request description says what the release changes: the nixpkgs
revision range with a compare link, the gcc and kernel versions before and
after, each tool's old and new version (flagged when it crosses a major
version, a minor one under 0.x included), and any held-back lockfile bump.

Re-running it for the same version is fine: a leftover `release/vX.Y.Z` branch
only means an earlier attempt, so the job warns and force-pushes over it. It has
to, because the CI workspace is reused between jobs and neither `git init`,
`git clean -ffdx` nor `git fetch --prune` removes a local branch — the branch an
earlier run created is still in the workspace even after it was deleted in the UI.

The merge request pipeline runs `check-x86_64` and `check-aarch64`, which
evaluate the image for their architecture and build every package in it that
cache.nixos.org cannot substitute, the packaged tools included. Anything a bump
can break before the image is assembled (renamed nixpkgs options, NixOS
assertions, home-manager changes, a bad source hash, a nixpkgs package that no
longer compiles and so was never cached) fails there instead of after tagging.

The package selection comes from a `nix build --dry-run` of the image: of the
derivations it would build, only those with a `src` that are neither
`preferLocalBuild` nor `allowSubstitutes = false` are built. That skips the
hundreds of generated config files, units and scripts, which build in
milliseconds but depend on most of the closure and would pull the whole image
down. The cost is that those are only built by
the tag pipeline, as is the image assembly itself.

Each check job links a short report from the merge request widget ("uncached
packages x86_64" / "aarch64"): the packages it had to build and which of them
failed, so a broken nixpkgs package is visible without reading the job log.

```sh
# same check locally
bash scripts/check.sh
bash scripts/check.sh --arch aarch64   # evaluate only, builds need a native host
```

After merging, tag the merge commit (`git tag vX.Y.Z && git push origin vX.Y.Z`)
to run the builds. `publish-images` then runs on its own and serves them, but only
once both builds have succeeded — one failed build fails the stage and nothing
is published.

### Image staging and retention

Build jobs upload into `~/inc/<pipeline-id>/` on the deploy host, one directory per
release attempt. `publish-images` refuses to serve unless that directory holds the
full set — one image per build job plus sidecars, every filename carrying the tag
being published — and each `sha256` matches, then moves them into `~/http/iso` and
removes the directory. A release that never finished is left where it is, so a
later publish cannot pick it up.

Retention, per variant and arch: the five newest versions, plus the newest patch of
each of the five newest minor series, and within one version only the newest build.
Staging directories from releases that never published are deleted by the nightly
`inc-prune` job once they are older than `INC_RETENTION_DAYS` (default 7).

Both host-side scripts take `--dry-run`, which reports every move and deletion
without touching anything.

The `prepare-release-mr` job needs a `RELEASE_TOKEN` CI variable: a project
access token with the developer role and the `write_repository` scope, masked.

### Attribution

The bump commits are authored by `sandbox-vm release bot`, not by whoever ran the
job, and carry a `Triggered-by: @user` trailer instead. Nothing generated them
but the script, and they cannot be signed: the merge request is pushed by the
access token's bot user, and a bot user cannot hold a signing key, so the commits
will always show as unverified. Attributing them to a person would claim
authorship that nothing backs. The merge request itself is assigned to whoever
triggered the pipeline.

Override the identity with `RELEASE_BOT_NAME` and `RELEASE_BOT_EMAIL`. If push
rules that verify commit authors are ever enabled, set `RELEASE_BOT_EMAIL` to the
token bot user's address (`project{id}_bot@noreply.<host>`, shown on its profile).

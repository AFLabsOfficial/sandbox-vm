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
`packages/*/update.sh`, and the patch version in `flake.nix`, then opens the
merge request. The job fails if nothing changed, or if the version is already
tagged.

Re-running it for the same version is fine: a leftover `release/vX.Y.Z` branch
only means an earlier attempt, so the job warns and force-pushes over it. It has
to, because the CI workspace is reused between jobs and neither `git init`,
`git clean -ffdx` nor `git fetch --prune` removes a local branch — the branch an
earlier run created is still in the workspace even after it was deleted in the UI.

The merge request pipeline runs `check-x86_64` and `check-aarch64`, which
instantiate both image derivations for their architecture and build the packaged
tools. Anything a bump can break at evaluation time (renamed nixpkgs options,
NixOS assertions, home-manager changes, a bad source hash) fails there instead of
after tagging. Assembling the images is not reproduced, so failures in that step
still only show up in the tag pipeline.

```sh
# same check locally
bash scripts/check.sh
bash scripts/check.sh --arch aarch64   # instantiate only, tools need a native host
```

After merging, tag the merge commit (`git tag vX.Y.Z && git push origin vX.Y.Z`)
to run the builds, then play `publish-images` to serve them.

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

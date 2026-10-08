#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
setup_colors

# trailer appended to every release commit, filled in by setup_identity
COMMIT_TRAILER=""

# lines for the merge request description, added by bump_lockfile and bump_tools
MR_NOTES=()

# what held the lockfile bump back, empty when it was not; set by bump_lockfile
HELD_BACK=""

# blockers named in the merge request before the rest are left to the job log
MAX_BLOCKERS=10

# prepare a release branch and open a merge request for it, reproducing the
# layout every release has:
#
#   chore: bump lockfile
#   chore: bump claude-code to v2.1.223
#   chore: bump codex to v0.146.1
#   chore: bump pi to v0.84.0
#   chore: bump version in flake.nix
#
# the lockfile bump is held back when the new nixpkgs would make the image
# build a package cache.nixos.org does not have: that almost always means hydra
# failed to build it, and the tool bumps should not wait for nixpkgs to fix it
#
# NOTE:(@janezicmatej) only bash, git, grep, coreutils and nix are used; the
# pinned ci nix image ships no sed, awk or jq. the per-package update.sh scripts
# pull their own deps through their nix-shell shebang

usage() {
	cat <<EOF
Usage: release-mr.sh [options]

Bump the lockfile, every packaged tool and the version string in flake.nix on a
release branch (one commit each), then push it and open a merge request.

Options:
  --dry-run          Prepare the branch locally, skip the push
  -h, --help         Show usage

Environment:
  RELEASE_TOKEN         gitlab token with the write_repository scope; used to
                        build the push url from the ci variables. keep it masked
  RELEASE_PUSH_URL      explicit push target, overrides RELEASE_TOKEN
  RELEASE_TARGET_BRANCH merge request target (default: CI_DEFAULT_BRANCH or main)
  RELEASE_MR_TITLE      merge request title (default: the new version)
  RELEASE_BOT_NAME      commit author name (default: sandbox-vm release bot)
  RELEASE_BOT_EMAIL     commit author email (default: noreply@CI_SERVER_HOST)
  RELEASE_LOCK          lockfile bump: auto holds it back when the new nixpkgs
                        has uncached packages in the image, force always takes
                        it, skip never does (default: auto)
  RELEASE_BUMP          version bump: patch, minor or major (default: patch)
EOF
	exit "${1:-0}"
}

# the `version = "X.Y.Z";` binding in a package.nix, without quotes
package_version() {
	version_binding "$REPO_DIR/packages/$1/package.nix" 'version = '
}

# vX.Y.Z bumped by patch, minor or major: vX.Y.(Z+1), vX.(Y+1).0, v(X+1).0.0.
# the bump is a human call, not derived from commit types: feat merges have
# shipped as patch releases before
next_version() {
	local v="${1#v}" bump="$2"
	local major="${v%%.*}" rest="${v#*.}"
	local minor="${rest%%.*}" patch="${rest##*.}"
	case "$bump" in
	patch) echo "v${major}.${minor}.$((patch + 1))" ;;
	minor) echo "v${major}.$((minor + 1)).0" ;;
	major) echo "v$((major + 1)).0.0" ;;
	*) die "RELEASE_BUMP must be patch, minor or major, not '$bump'" ;;
	esac
}

# the nixpkgs revision flake.lock pins
lock_rev() {
	nix eval --raw --impure --expr \
		"(builtins.fromJSON (builtins.readFile \"$REPO_DIR/flake.lock\")).nodes.nixpkgs.locked.rev"
}

# compiler and kernel the image is built with; a lockfile bump that moves
# either is the one most likely to break packages, gcc 16 broke contour
toolchain() {
	# shellcheck disable=SC2016 # ${...} is nix interpolation, not bash
	nix eval --raw ".#nixosConfigurations.sandbox" --apply \
		'c: "gcc ${c.pkgs.stdenv.cc.cc.version}, linux ${c.config.boot.kernelPackages.kernel.version}"'
}

# whether X.Y.Z -> X'.Y'.Z' crosses a major version, counting a minor bump
# under 0.x as major the way semver does
is_major_bump() {
	local old="$1" new="$2"
	local old_major="${old%%.*}" new_major="${new%%.*}"
	local old_rest="${old#*.}" new_rest="${new#*.}"
	[ "$old_major" != "$new_major" ] && return 0
	[ "$old_major" = 0 ] && [ "${old_rest%%.*}" != "${new_rest%%.*}" ] && return 0
	return 1
}

# the packages the image would have to build after a lockfile change, on both
# arches, as `<name> (<arch>)` lines. the packaged tools are left out by their
# exact derivation, every flake package but the image itself: every lockfile
# bump changes them, so they are never cached, and the mr check builds them. an
# arch the new lock no longer evaluates for is listed too. a dry-run is
# system-agnostic, so the x86 job can judge aarch64 as well
lock_blockers() {
	local arch entry drv own_drvs
	local -A own=()

	for arch in x86_64 aarch64; do
		mkdir -p "$TMP_DIR/$arch"
		info "checking the new lockfile against the binary cache ($arch)"
		# a nixpkgs the image no longer evaluates against blocks the bump the
		# same way, so the tool bumps still go out. a separate bash -e process
		# rather than a subshell under `if`, which would switch errexit off
		# inside it and let a failed step pass as an empty selection
		# shellcheck disable=SC2016 # expanded by the inner bash
		if ! bash -euo pipefail -c 'source "$1"; setup_colors; uncached_packages "$2" "$3"' _ \
			"$SCRIPT_DIR/lib.sh" ".#packages.${arch}-linux.sandbox-headless" "$TMP_DIR/$arch" \
			>"$TMP_DIR/$arch/packages"; then
			echo "evaluation failed ($arch), see the job log"
			continue
		fi

		# a plain assignment, so a failed eval stops the script instead of
		# leaving the tools in the list as blockers
		own_drvs=$(nix eval --raw ".#packages.${arch}-linux" --apply \
			'ps: builtins.concatStringsSep "\n" (map (p: p.drvPath) (builtins.attrValues (removeAttrs ps [ "sandbox-headless" ])))')
		own=()
		while IFS= read -r drv; do
			own[$drv]=1
		done <<<"$own_drvs"

		while IFS= read -r entry; do
			[ -n "${own[${entry%^\*}]:-}" ] || echo "$(package_name "$entry") ($arch)"
		done <"$TMP_DIR/$arch/packages"
	done
}

# rewrite the version binding in place, keeping the file's mode
set_flake_version() {
	local old="$1" new="$2" tmp="$TMP_DIR/flake.nix"
	while IFS= read -r line; do
		printf '%s\n' "${line//version = \"$old\";/version = \"$new\";}"
	done <"$REPO_DIR/flake.nix" >"$tmp"
	cat "$tmp" >"$REPO_DIR/flake.nix"
}

# commit the given paths if any of them changed; returns 1 when there was
# nothing to commit
#
# --no-gpg-sign because these are machine commits: signing them with whatever
# key the runner or a local clone happens to have would attribute them to a
# person who did not write them
commit_if_changed() {
	local message="$1"
	shift
	git -C "$REPO_DIR" diff --quiet -- "$@" && return 1
	git -C "$REPO_DIR" add -- "$@"
	local args=(-q --no-gpg-sign -m "$message")
	[ -n "$COMMIT_TRAILER" ] && args+=(-m "$COMMIT_TRAILER")
	git -C "$REPO_DIR" commit "${args[@]}"
	info "committed: $message"
}

# WARN:(@janezicmatej) these commits are authored by a bot identity, never by
# whoever triggered the pipeline. the author field is a claim about who wrote a
# change, and there is no way to back that claim here: a project access token
# bot user cannot hold a signing key, so nothing in the release branch can ever
# show up as verified. the human is recorded in a Triggered-by trailer instead
setup_identity() {
	GIT_AUTHOR_NAME="${RELEASE_BOT_NAME:-sandbox-vm release bot}"
	GIT_AUTHOR_EMAIL="${RELEASE_BOT_EMAIL:-noreply@${CI_SERVER_HOST:-localhost}}"
	GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
	GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
	export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

	COMMIT_TRAILER=""
	[ -n "${GITLAB_USER_LOGIN:-}" ] && COMMIT_TRAILER="Triggered-by: @${GITLAB_USER_LOGIN}"

	info "committing as $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>${COMMIT_TRAILER:+ (${COMMIT_TRAILER})}"
}

# update flake.lock and commit it, unless <mode> is skip, or auto finds the new
# nixpkgs blocked; notes the nixpkgs range and toolchain change it brings
bump_lockfile() {
	local mode="$1"

	if [ "$mode" = skip ]; then
		info "leaving the lockfile alone (RELEASE_LOCK=skip)"
		MR_NOTES+=("lockfile not bumped: RELEASE_LOCK=skip")
		return 0
	fi

	local old_rev old_toolchain
	old_rev=$(lock_rev)
	old_toolchain=$(toolchain) || old_toolchain="unknown, the lock does not evaluate"

	nix flake update

	if [ "$mode" = auto ] && ! git diff --quiet -- flake.lock; then
		# written to a file rather than read from a process substitution, so
		# set -e still applies inside lock_blockers
		local blockers=()
		lock_blockers >"$TMP_DIR/blockers"
		mapfile -t blockers <"$TMP_DIR/blockers"
		if [ ${#blockers[@]} -gt 0 ]; then
			warn "holding back the lockfile bump, the new nixpkgs is blocked by:"
			printf '  %s\n' "${blockers[@]}" >&2
			git checkout -q -- flake.lock
			# a long list means the cache was unreachable or a whole arch lags
			# rather than a few packages failing on hydra; the push option
			# carrying it is not the place for all of them
			HELD_BACK=$(join_list "${blockers[@]:0:$MAX_BLOCKERS}")
			[ ${#blockers[@]} -le "$MAX_BLOCKERS" ] ||
				HELD_BACK+=" and $((${#blockers[@]} - MAX_BLOCKERS)) more, see the job log"
			MR_NOTES+=("lockfile bump held back, the new nixpkgs fails to evaluate or would build packages cache.nixos.org does not have (most likely failing on hydra): $HELD_BACK. rerun with RELEASE_LOCK=force to take it anyway")
		fi
	fi

	commit_if_changed "chore: bump lockfile" flake.lock || return 0

	local new_rev new_toolchain
	new_rev=$(lock_rev)
	# RELEASE_LOCK=force can commit a lock the image no longer evaluates
	# against; the release still goes out and the mr check shows why
	new_toolchain=$(toolchain) || new_toolchain="unknown, the new lock does not evaluate"
	# the lock can change without nixpkgs moving, when only home-manager did
	if [ "$old_rev" = "$new_rev" ]; then
		MR_NOTES+=("lockfile: nixpkgs unchanged at ${new_rev:0:12}, other inputs updated")
	else
		MR_NOTES+=("nixpkgs: ${old_rev:0:12} -> ${new_rev:0:12}, https://github.com/NixOS/nixpkgs/compare/${old_rev}...${new_rev}")
	fi
	if [ "$old_toolchain" = "$new_toolchain" ]; then
		MR_NOTES+=("toolchain: $new_toolchain (unchanged)")
	else
		MR_NOTES+=("toolchain: $old_toolchain -> $new_toolchain")
	fi
}

# run every packages/*/update.sh and commit each tool that moved, noting old
# and new versions. alphabetical, so the branch history is the same no matter
# where it runs
bump_tools() {
	local updater name old new major changes=()
	for updater in packages/*/update.sh; do
		name=$(basename "$(dirname "$updater")")
		[ -x "$updater" ] || die "$updater is not executable"
		old=$(package_version "$name")
		"$updater"
		new=$(package_version "$name")
		commit_if_changed "chore: bump $name to v$new" "packages/$name" || continue
		major=""
		is_major_bump "$old" "$new" && major=" (major)"
		changes+=("$name $old -> $new$major")
	done
	if [ ${#changes[@]} -gt 0 ]; then
		MR_NOTES+=("tools: $(join_list "${changes[@]}")")
	fi
}

main() {
	local dry_run=false

	while [ $# -gt 0 ]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		-h | --help) usage ;;
		*) die_usage "unknown option: $1" ;;
		esac
	done

	require_cmd git
	require_cmd nix

	cd "$REPO_DIR"

	[ -z "$(git status --porcelain)" ] || die "working tree is dirty, commit or stash first"

	local lock_mode="${RELEASE_LOCK:-auto}"
	case "$lock_mode" in
	auto | force | skip) ;;
	*) die "RELEASE_LOCK must be auto, force or skip, not '$lock_mode'" ;;
	esac

	setup_tmp_dir

	local current next branch target start_ref push_url
	current=$(flake_version)
	next=$(next_version "$current" "${RELEASE_BUMP:-patch}")
	branch="release/$next"
	target="${RELEASE_TARGET_BRANCH:-${CI_DEFAULT_BRANCH:-main}}"
	start_ref=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
	push_url=$(resolve_push_url)

	# a tag is a released version and stays fatal; a leftover release branch is
	# not, it just means an earlier attempt at this same version, so it gets
	# replaced. the remote is checked too because a ci checkout may not have
	# fetched the tags
	git rev-parse -q --verify "refs/tags/$next" >/dev/null && die "tag $next already exists"

	# NOTE:(@janezicmatej) the ci workspace is reused between jobs and neither
	# `git init`, `git clean -ffdx` nor `git fetch --prune` removes a local
	# branch, so the branch an earlier run created is still here even after it
	# was deleted in the ui
	git rev-parse -q --verify "refs/heads/$branch" >/dev/null &&
		warn "$branch already exists locally, resetting it to $start_ref"

	local remote_sha=""
	if [ "$dry_run" = false ]; then
		local remote_tag
		remote_tag=$(remote_ref_sha "$push_url" "refs/tags/$next")
		[ -n "$remote_tag" ] && die "tag $next already exists on the remote"

		remote_sha=$(remote_ref_sha "$push_url" "refs/heads/$branch")
		[ -n "$remote_sha" ] &&
			warn "$branch already exists on the remote at ${remote_sha:0:8}, force-pushing over it"
	fi

	setup_identity

	info "preparing $next (current: $current) on $branch"
	git checkout -q -B "$branch"

	bump_lockfile "$lock_mode"
	bump_tools

	if [ "$(git rev-list --count "$start_ref..HEAD")" -eq 0 ]; then
		git checkout -q "$start_ref"
		git branch -q -D "$branch"
		[ -z "$HELD_BACK" ] ||
			die "nothing to release: the lockfile bump is held back ($HELD_BACK) and all packaged tools are already current; rerun with RELEASE_LOCK=force to release the new lock anyway"
		die "nothing to release: no lockfile bump and all packaged tools are already current"
	fi

	set_flake_version "$current" "$next"
	commit_if_changed "chore: bump version in flake.nix" flake.nix ||
		die "flake.nix version bump changed nothing, expected $current"

	# push option values cannot hold a newline; per gitlab docs
	# (topics/git/commit.md, push options) a literal \n in the description
	# becomes one
	local description note
	description="release $next${CI_JOB_URL:+, prepared by $CI_JOB_URL}${GITLAB_USER_LOGIN:+ for @$GITLAB_USER_LOGIN}. once merged into the default branch, tag-release tags $next, which builds and publishes the images; with RELEASE_AUTO_TAG=false, tag it by hand."
	for note in "${MR_NOTES[@]}"; do
		description+='\n\n'"$note"
	done

	if [ "$dry_run" = true ]; then
		info "dry run: $branch prepared locally with $(git rev-list --count "$start_ref..HEAD") commits, not pushed"
		info "merge request description:"
		printf '%b\n' "$description" >&2
		return 0
	fi

	# push options open the merge request, so no api token or jq is needed
	local push_opts=(
		-o merge_request.create
		-o merge_request.target="$target"
		-o merge_request.title="${RELEASE_MR_TITLE:-$next}"
		-o merge_request.description="$description"
		-o merge_request.remove_source_branch
	)

	# the token's bot user opens the mr and gitlab makes it the assignee by
	# default; hand it to whoever triggered the pipeline instead. the id is used
	# rather than the username because gitlab falls back to the pusher when it
	# cannot resolve the name
	[ -n "${GITLAB_USER_ID:-}" ] && push_opts+=(-o merge_request.assign="$GITLAB_USER_ID")

	# replacing an earlier attempt at this version. the lease is the sha the
	# check above saw, so a branch that moved in between is not clobbered
	[ -n "$remote_sha" ] && push_opts+=("--force-with-lease=refs/heads/$branch:$remote_sha")

	git push "${push_opts[@]}" "$push_url" "HEAD:refs/heads/$branch"

	info "pushed $branch, merge request targets $target${GITLAB_USER_ID:+, assigned to ${GITLAB_USER_LOGIN:-user $GITLAB_USER_ID}}"
}

main "$@"

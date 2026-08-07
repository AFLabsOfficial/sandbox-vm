#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
setup_colors

# trailer appended to every release commit, filled in by setup_identity
COMMIT_TRAILER=""

# prepare a release branch and open a merge request for it, reproducing the
# layout every release has:
#
#   chore: bump lockfile
#   chore: bump claude-code to v2.1.223
#   chore: bump codex to v0.146.1
#   chore: bump pi to v0.84.0
#   chore: bump version in flake.nix
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
EOF
	exit "${1:-0}"
}

# the `version = "vX.Y.Z";` binding in flake.nix, without quotes
flake_version() {
	local line
	line=$(grep -m1 -E '^[[:space:]]*version = "v[0-9]+\.[0-9]+\.[0-9]+";' "$REPO_DIR/flake.nix") ||
		die "no version binding found in flake.nix"
	line="${line#*\"}"
	echo "${line%%\"*}"
}

# the `version = "X.Y.Z";` binding in a package.nix, without quotes
package_version() {
	local line
	line=$(grep -m1 'version = ' "$REPO_DIR/packages/$1/package.nix") ||
		die "no version binding found in packages/$1/package.nix"
	line="${line#*\"}"
	echo "${line%%\"*}"
}

# vX.Y.Z -> vX.Y.(Z+1)
next_patch() {
	local v="${1#v}"
	local major="${v%%.*}" rest="${v#*.}"
	local minor="${rest%%.*}" patch="${rest##*.}"
	echo "v${major}.${minor}.$((patch + 1))"
}

# rewrite the version binding in place, keeping the file's mode
set_flake_version() {
	local old="$1" new="$2" tmp
	tmp=$(mktemp)
	while IFS= read -r line; do
		printf '%s\n' "${line//version = \"$old\";/version = \"$new\";}"
	done <"$REPO_DIR/flake.nix" >"$tmp"
	cat "$tmp" >"$REPO_DIR/flake.nix"
	rm -f "$tmp"
}

# commit the given paths if any of them changed; returns 1 when there was
# nothing to commit so callers can count real bumps.
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

# sha a remote ref points at, empty when the ref does not exist.
#
# --exit-code makes ls-remote exit 2 when the ref is absent, so anything else is
# a real failure and must not be mistaken for "not taken yet". call this in a
# plain assignment, never inside $( ) in a test: die would only leave the subshell
# and an unreachable remote would read as an absent ref
remote_ref_sha() {
	local out status=0
	out=$(git ls-remote --exit-code "$1" "$2" 2>/dev/null) || status=$?
	case "$status" in
	0) printf '%s' "${out%%[[:space:]]*}" ;;
	2) printf '' ;;
	*) die "cannot reach the remote to check $2 (git exited $status)" ;;
	esac
}

# WARN:(@janezicmatej) the token ends up in the url, which git prints back on
# some errors; RELEASE_TOKEN must be a masked ci variable
resolve_push_url() {
	if [ -n "${RELEASE_PUSH_URL:-}" ]; then
		echo "$RELEASE_PUSH_URL"
	elif [ -n "${RELEASE_TOKEN:-}" ]; then
		[ -n "${CI_SERVER_HOST:-}" ] && [ -n "${CI_PROJECT_PATH:-}" ] ||
			die "RELEASE_TOKEN set outside ci: pass RELEASE_PUSH_URL instead"
		echo "https://oauth2:${RELEASE_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
	else
		echo origin
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

	local current next branch target start_ref push_url
	current=$(flake_version)
	next=$(next_patch "$current")
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

	local bumps=0

	nix flake update
	commit_if_changed "chore: bump lockfile" flake.lock && bumps=$((bumps + 1))

	# alphabetical, so the branch history is the same no matter where it runs
	local updater name
	for updater in packages/*/update.sh; do
		name=$(basename "$(dirname "$updater")")
		[ -x "$updater" ] || die "$updater is not executable"
		"$updater"
		commit_if_changed "chore: bump $name to v$(package_version "$name")" "packages/$name" &&
			bumps=$((bumps + 1))
	done

	if [ "$bumps" -eq 0 ]; then
		git checkout -q "$start_ref"
		git branch -q -D "$branch"
		die "nothing to release: lockfile and all packaged tools are already current"
	fi

	set_flake_version "$current" "$next"
	commit_if_changed "chore: bump version in flake.nix" flake.nix ||
		die "flake.nix version bump changed nothing, expected $current"

	if [ "$dry_run" = true ]; then
		info "dry run: $branch prepared locally with $((bumps + 1)) commits, not pushed"
		return 0
	fi

	# push options open the merge request, so no api token or jq is needed
	local push_opts=(
		-o merge_request.create
		-o merge_request.target="$target"
		-o merge_request.title="${RELEASE_MR_TITLE:-$next}"
		-o merge_request.description="release $next${CI_JOB_URL:+, prepared by $CI_JOB_URL}${GITLAB_USER_LOGIN:+ for @$GITLAB_USER_LOGIN}. tag $next on $target after merging to trigger the image builds."
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

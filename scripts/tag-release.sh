#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
setup_colors

# tag the version in flake.nix once it reaches the default branch, which is
# what starts the image builds. the version is what decides, not the merge: it
# works the same for a merge from the gitlab ui and a local `git merge`, and a
# feature merge leaves the version alone, so its tag already exists and nothing
# happens. the tag goes on the commit that bumped the version, so a release
# whose own tag job failed is tagged correctly by the next push
#
# NOTE:(@janezicmatej) only bash, git, grep and coreutils are used; the pinned
# ci nix image ships no sed, awk or jq

usage() {
	cat <<EOF
Usage: tag-release.sh [options]

Tag the commit that set the version in flake.nix and push the tag, unless that
version is already tagged. The commit is found on the first-parent history, so
it is the merge commit for a merged release branch and the bump commit itself
for a fast-forward.

Options:
  --dry-run          Report what would be tagged, skip the push
  -h, --help         Show usage

Environment:
  RELEASE_TOKEN         gitlab token with the write_repository scope; used to
                        build the push url from the ci variables. keep it masked
  RELEASE_PUSH_URL      explicit push target, overrides RELEASE_TOKEN
  CI_COMMIT_SHA         commit whose version to tag (default: HEAD)
EOF
	exit "${1:-0}"
}

# commit the remote tag points at, empty when the tag does not exist; set by
# lookup_tag
TAGGED=""

# set TAGGED for tag <name> on <remote>. an annotated tag points at a tag
# object, so its peeled ^{} entry is asked first. it sets a global instead of
# printing because remote_ref_sha must run in a plain assignment, never inside
# $( ): an unreachable remote would otherwise read as an absent tag and the
# script would go on to push
lookup_tag() {
	TAGGED=$(remote_ref_sha "$1" "refs/tags/$2^{}")
	[ -n "$TAGGED" ] || TAGGED=$(remote_ref_sha "$1" "refs/tags/$2")
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

	cd "$REPO_DIR"

	local head version sha push_url flake
	head="${CI_COMMIT_SHA:-$(git rev-parse HEAD)}"
	flake=$(git show "$head:flake.nix") || die "cannot read flake.nix at $head"
	version=$(flake_version /dev/stdin <<<"$flake")
	push_url=$(resolve_push_url)

	lookup_tag "$push_url" "$version"
	if [ -n "$TAGGED" ]; then
		info "$version is already tagged on ${TAGGED:0:8}, nothing to do"
		return 0
	fi

	# the newest first-parent commit that changed the number of version lines
	# reading $version: the one that introduced it, since head still has it
	sha=$(git log --first-parent -1 --format=%H -S"version = \"$version\";" "$head" -- flake.nix)
	[ -n "$sha" ] || die "no commit introducing $version found, the clone needs more history"
	[ "$sha" = "$head" ] || warn "$version was bumped in ${sha:0:8}, not ${head:0:8}; its own tag job did not tag it"

	if [ "$dry_run" = true ]; then
		info "dry run: would tag ${sha:0:8} as $version"
		return 0
	fi

	# a lightweight tag, the same thing `git tag vX.Y.Z` makes by hand. pushed
	# with RELEASE_TOKEN rather than the job token, because tags the job token
	# pushes do not start a pipeline
	info "tagging ${sha:0:8} as $version"
	if git push "$push_url" "$sha:refs/tags/$version"; then
		info "pushed $version, the tag pipeline builds and publishes the images"
		return 0
	fi

	# a concurrent job or a hand-pushed tag may have won the race, which is
	# fine when it tagged the same commit
	lookup_tag "$push_url" "$version"
	[ "$TAGGED" = "$sha" ] && info "$version was tagged on ${sha:0:8} in the meantime" && return 0
	die "pushing $version failed${TAGGED:+, it now points at ${TAGGED:0:8}}"
}

main "$@"

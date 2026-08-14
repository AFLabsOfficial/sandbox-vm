#!/usr/bin/env bash
set -euo pipefail

# runs on the deploy host, not on a runner: it is scp'd over and executed there,
# so it stays self-contained and does not source lib.sh
#
# move one release out of its staging directory into the served tree, then drop
# releases that fall outside the retention policy
#
# layout:
#   ~/inc/<pipeline-id>/                     one staging dir per release attempt
#   │   ├── sandbox-headless-x86_64-v0.1.0-20260306.abc1234.qcow2
#   │   └── sandbox-headless-x86_64-v0.1.0-20260306.abc1234.sha256
#   ~/http/iso/
#   ├── sandbox-headless-x86_64-v0.1.0-20260306.abc1234.qcow2
#   ├── sandbox-headless-x86_64-v0.1.0-20260306.abc1234.sha256
#   └── ...

INC_DIR="${HOME}/inc"
ISO_DIR="${HOME}/http/iso"

# retention, per variant+arch group: the N newest versions, plus the newest patch
# of each of the M newest minor series
KEEP_RECENT=5
KEEP_MINORS=5

EXPECT=4
DRY_RUN=false
ID=""
TAG=""

die() {
	echo "error: $*" >&2
	exit 1
}

usage() {
	cat <<EOF
Usage: publish-images.sh --id <staging-id> --tag <vX.Y.Z> [options]

Verify the staged release, move it into $ISO_DIR, then apply retention.

Options:
  --id <id>          Staging directory under ~/inc (required)
  --tag <vX.Y.Z>     Version being published; every staged file must carry it
  --expect <n>       Images required in the staging dir (default: $EXPECT)
  --keep-recent <n>  Newest versions to keep per variant+arch (default: $KEEP_RECENT)
  --keep-minors <n>  Minor series to keep a newest patch of (default: $KEEP_MINORS)
  --dry-run          Report what would move and be deleted, change nothing
  -h, --help         Show usage
EOF
	exit "${1:-0}"
}

sha256_check() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum -c --status "$file"
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 -c -s "$file"
	else
		die "sha256sum or shasum required"
	fi
}

# strict X.Y.Z only. anything else is left alone rather than deleted: retention
# must never remove a file whose version it cannot reason about
parse_version() {
	local v="${1#v}"
	case "$v" in
	[0-9]*.[0-9]*.[0-9]*) ;;
	*) return 1 ;;
	esac
	local major="${v%%.*}" rest="${v#*.}"
	local minor="${rest%%.*}" patch="${rest##*.}"
	case "$major$minor$patch" in
	*[!0-9]*) return 1 ;;
	esac
	printf '%s %s %s' "$major" "$minor" "$patch"
}

# newest first, by version number rather than by mtime: a rebuild of an old
# release must not outrank a newer one
sort_versions_desc() {
	local v
	while IFS= read -r v; do
		[ -n "$v" ] && printf '%s\n' "${v#v}"
	done | sort -t. -k1,1nr -k2,2nr -k3,3nr | while IFS= read -r v; do
		printf 'v%s\n' "$v"
	done
}

move_release() {
	local staging="$INC_DIR/$ID"
	[ -d "$staging" ] || die "no staging directory $staging"

	local images=() image
	while IFS= read -r image; do
		images+=("$image")
	done < <(find "$staging" -maxdepth 1 -name 'sandbox-*.qcow2' | sort)

	[ "${#images[@]}" -eq "$EXPECT" ] ||
		die "expected $EXPECT images in $staging, found ${#images[@]}: refusing to publish a partial release"

	local name
	for image in "${images[@]}"; do
		name="$(basename "$image")"
		case "$name" in
		*"-$TAG-"*) ;;
		*) die "$name does not belong to $TAG" ;;
		esac
		[ -f "${image%.qcow2}.sha256" ] || die "no .sha256 sidecar for $name"
	done

	# verify on this side of the wire: a truncated upload must fail the job
	# rather than reach a user's pull.sh
	echo "verifying ${#images[@]} image(s)"
	for image in "${images[@]}"; do
		(cd "$staging" && sha256_check "$(basename "${image%.qcow2}.sha256")") ||
			die "sha256 mismatch for $(basename "$image")"
	done

	mkdir -p "$ISO_DIR"
	for image in "${images[@]}"; do
		name="$(basename "$image")"
		echo "publishing $name"
		if [ "$DRY_RUN" = false ]; then
			mv "$image" "$ISO_DIR/"
			mv "${image%.qcow2}.sha256" "$ISO_DIR/"
		fi
	done

	if [ "$DRY_RUN" = false ]; then
		rmdir "$staging" || die "$staging is not empty after publishing"
	fi
}

apply_retention() {
	local groups=() group
	while IFS= read -r group; do
		groups+=("$group")
	done < <(find "$ISO_DIR" -maxdepth 1 -name 'sandbox-*.qcow2' -printf '%f\n' 2>/dev/null |
		while IFS= read -r name; do
			IFS=- read -r prefix variant arch _ <<<"${name%.qcow2}"
			[ "$prefix" = sandbox ] && printf '%s-%s-%s\n' "$prefix" "$variant" "$arch"
		done | sort -u)

	for group in "${groups[@]}"; do
		retain_group "$group"
	done
}

retain_group() {
	local group="$1"
	local -A version_of=() keep=() minor_seen=()
	local name version major minor

	local files=()
	while IFS= read -r name; do
		version="$(printf '%s' "${name%.qcow2}" | cut -d- -f4)"
		if ! parse_version "$version" >/dev/null; then
			echo "  keeping $name (unrecognised version)"
			continue
		fi
		files+=("$name")
		version_of["$name"]="$version"
	done < <(find "$ISO_DIR" -maxdepth 1 -name "$group-v*.qcow2" -printf '%f\n' | sort)

	[ "${#files[@]}" -gt 0 ] || return 0

	# the release being published counts as present even on a dry run, where it
	# has not been moved yet: otherwise a dry run reports fewer deletions than
	# the real run it is meant to preview
	local versions=()
	while IFS= read -r version; do
		versions+=("$version")
	done < <(printf '%s\n' "${version_of[@]}" "$TAG" | sort -u | sort_versions_desc)

	# the release just published is kept no matter where it sorts, so publishing
	# an older version than what is already served cannot delete it immediately
	keep["$TAG"]=1

	local recent=0 minors=0
	for version in "${versions[@]}"; do
		if [ "$recent" -lt "$KEEP_RECENT" ]; then
			keep["$version"]=1
			recent=$((recent + 1))
		fi
		read -r major minor _ <<<"$(parse_version "$version")"
		if [ -z "${minor_seen["$major.$minor"]:-}" ]; then
			minor_seen["$major.$minor"]=1
			if [ "$minors" -lt "$KEEP_MINORS" ]; then
				keep["$version"]=1
				minors=$((minors + 1))
			fi
		fi
	done

	# within a kept version the newest build wins: a retried pipeline publishes the
	# same version again with a later build date, and two builds of one version
	# would otherwise pile up and make "latest" ambiguous for pull.sh
	local -A newest_of=()
	for name in "${files[@]}"; do
		version="${version_of[$name]}"
		[ -n "${keep[$version]:-}" ] || continue
		newest_of["$version"]="$name"
	done

	for name in "${files[@]}"; do
		version="${version_of[$name]}"
		if [ -z "${keep[$version]:-}" ]; then
			echo "  deleting $name ($version outside retention)"
		elif [ "${newest_of[$version]}" != "$name" ]; then
			echo "  deleting $name (superseded build of $version)"
		else
			continue
		fi
		if [ "$DRY_RUN" = false ]; then
			rm -f "$ISO_DIR/$name" "$ISO_DIR/${name%.qcow2}.sha256"
		fi
	done
}

main() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--id)
			ID="$2"
			shift 2
			;;
		--tag)
			TAG="$2"
			shift 2
			;;
		--expect)
			EXPECT="$2"
			shift 2
			;;
		--keep-recent)
			KEEP_RECENT="$2"
			shift 2
			;;
		--keep-minors)
			KEEP_MINORS="$2"
			shift 2
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		-h | --help) usage ;;
		*) die "unknown option: $1" ;;
		esac
	done

	[ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash 4 or newer required"
	[ -n "$ID" ] || die "--id is required"
	[ -n "$TAG" ] || die "--tag is required"

	[ "$DRY_RUN" = true ] && echo "dry run: nothing will be moved or deleted"

	move_release
	echo "retention: keeping the $KEEP_RECENT newest versions plus the newest patch of the $KEEP_MINORS newest minors, per variant and arch"
	apply_retention
}

main "$@"

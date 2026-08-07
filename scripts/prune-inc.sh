#!/usr/bin/env bash
set -euo pipefail

# runs on the deploy host, not on a runner: it is scp'd over and executed there,
# so it stays self-contained and does not source lib.sh
#
# remove staging directories left behind by releases that never published. a
# failed, cancelled or killed pipeline strands gigabytes in ~/inc and nothing
# else ever collects it. loose files are swept too, which clears whatever the
# old flat ~/inc layout left behind

INC_DIR="${HOME}/inc"
DAYS=7
DRY_RUN=false

die() {
	echo "error: $*" >&2
	exit 1
}

usage() {
	cat <<EOF
Usage: prune-inc.sh [options]

Delete anything in $INC_DIR older than the retention window.

Options:
  --days <n>         Age threshold in days (default: $DAYS)
  --dry-run          Report what would be deleted, delete nothing
  -h, --help         Show usage
EOF
	exit "${1:-0}"
}

main() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--days)
			DAYS="$2"
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

	case "$DAYS" in
	'' | *[!0-9]*) die "--days must be a whole number of days" ;;
	esac

	[ -d "$INC_DIR" ] || {
		echo "$INC_DIR does not exist, nothing to prune"
		return 0
	}

	[ "$DRY_RUN" = true ] && echo "dry run: nothing will be deleted"
	echo "pruning entries in $INC_DIR older than $DAYS day(s)"

	local stale=() entry
	while IFS= read -r entry; do
		stale+=("$entry")
	done < <(find "$INC_DIR" -mindepth 1 -maxdepth 1 -mtime "+$DAYS" | sort)

	if [ "${#stale[@]}" -eq 0 ]; then
		echo "nothing stale"
		return 0
	fi

	for entry in "${stale[@]}"; do
		echo "  deleting $(basename "$entry") ($(du -sh "$entry" | cut -f1))"
		[ "$DRY_RUN" = false ] && rm -rf "$entry"
	done

	if [ "$DRY_RUN" = true ]; then
		echo "would prune ${#stale[@]} entries"
	else
		echo "pruned ${#stale[@]} entries, $(du -sh "$INC_DIR" | cut -f1) left in $INC_DIR"
	fi
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
setup_colors

# verify a tagged build would get off the ground, without paying for a full
# image build: evaluate the image and build every real package in it that
# cache.nixos.org cannot substitute
#
# NOTE:(@janezicmatej) `nix flake check` is deliberately not used. it evaluates
# the darwin outputs ci never builds, and doing every output in one process
# peaks well over 3G and gets oom killed

# merge request report file, empty when none was asked for
REPORT=""

usage() {
	cat <<EOF
Usage: check.sh [options]

Evaluate the sandbox image and build the packages in it that the binary cache
does not have. Fails on anything a bump can break before the image is
assembled: renamed nixpkgs options, nixos assertions, home-manager changes, bad
source hashes, and packages that no longer compile.

Options:
  --arch <arch>      Architecture to check (default: host)
  --report <file>    Also write the uncached packages and each one's build
                     result to <file>, for the merge request widget
  -h, --help         Show usage
EOF
	exit "${1:-0}"
}

# write stdin to the report, when one was asked for
to_report() {
	if [ -n "$REPORT" ]; then
		cat >"$REPORT"
	else
		cat >/dev/null
	fi
}

# the derivations a `nix build --keep-going` log reports as failed, as
# `<drv> builder` when its own build failed or `<drv> dependency` when one of
# its inputs did. nix prints `error: Cannot build '<drv>'.` followed by a
# `Reason:` line for each
build_failures() {
	local line drv=""
	while IFS= read -r line; do
		case "$line" in
		*"Cannot build '"*)
			drv="${line#*Cannot build \'}"
			drv="${drv%%\'*}"
			;;
		*"Reason: "*)
			if [ -n "$drv" ]; then
				case "$line" in
				*"dependency failed"* | *"dependencies failed"*) echo "$drv dependency" ;;
				*) echo "$drv builder" ;;
				esac
				drv=""
			fi
			;;
		esac
	done <"$1"
}

# report lines for a build log: each selected package as built, failed, or
# blocked by a failed dependency, then any failure outside the selection, like
# a fetch with a wrong hash, since that is the one to fix
report_builds() {
	local log="$1"
	shift
	local -A kind=() selected=()
	local drv reason package name

	while read -r drv reason; do
		kind[$drv]="$reason"
	done < <(build_failures "$log")

	for package in "$@"; do
		drv="${package%^\*}"
		selected[$drv]=1
		name=$(package_name "$package")
		case "${kind[$drv]:-}" in
		builder) echo "  FAILED   $name" ;;
		dependency) echo "  blocked  $name, a dependency failed" ;;
		*)
			if nix path-info "$package" >/dev/null 2>&1; then
				echo "  built    $name"
			else
				echo "  missing  $name, not built, see the job log"
			fi
			;;
		esac
	done

	for drv in "${!kind[@]}"; do
		if [ "${kind[$drv]}" = builder ] && [ -z "${selected[$drv]:-}" ]; then
			echo "  FAILED   $(package_name "$drv"), needed by the above"
		fi
	done
}

main() {
	local arch=""

	while [ $# -gt 0 ]; do
		case "$1" in
		--arch)
			arch="$2"
			shift 2
			;;
		--report)
			REPORT="$2"
			shift 2
			;;
		-h | --help) usage ;;
		*) die_usage "unknown option: $1" ;;
		esac
	done

	require_cmd nix
	arch=$(normalize_arch "$arch")

	# relative to where the script was called from, before the cd below. the
	# placeholder stays if evaluation dies
	if [ -n "$REPORT" ]; then
		REPORT="$(cd "$(dirname "$REPORT")" && pwd)/$(basename "$REPORT")"
	fi
	echo "sandbox-headless ($arch): evaluation did not finish, see the job log" | to_report

	cd "$REPO_DIR"
	setup_tmp_dir

	# the dry-run evaluates the image, which forces system.build.toplevel, so
	# the whole nixos and home-manager evaluation is covered here, and it asks
	# the substituters which paths they have. written to a file rather than
	# captured, so a failed evaluation stops the script
	info "evaluating sandbox-headless ($arch)"
	uncached_packages ".#packages.${arch}-linux.sandbox-headless" "$TMP_DIR" >"$TMP_DIR/packages"

	local packages=() package
	mapfile -t packages <"$TMP_DIR/packages"
	if [ ${#packages[@]} -eq 0 ]; then
		info "nothing to build: every package is substitutable or already in the store"
		echo "sandbox-headless ($arch): nothing to build, every package is substitutable or already built" | to_report
		return 0
	fi

	info "${#packages[@]} uncached packages ($arch):"
	printf '  %s\n' "${packages[@]}" >&2

	local host_arch
	host_arch=$(normalize_arch "")
	if [ "$arch" != "$host_arch" ]; then
		warn "skipping builds: $arch cannot be built on a $host_arch host"
		{
			echo "sandbox-headless ($arch): uncached packages, not built on a $host_arch host (${#packages[@]})"
			for package in "${packages[@]}"; do
				echo "  $(package_name "$package")"
			done
		} | to_report
		return 0
	fi

	# this includes the packaged tools whenever a bump changed them, which is
	# what validates the hashes the bump commit wrote. a failed build is not
	# cached, so a broken package is rebuilt and caught again on every run
	#
	# the log is kept for the report, and still streamed to the job log. the
	# report lists what is being built first, so a job that times out or is
	# cancelled mid-build does not leave the evaluation placeholder behind
	{
		echo "sandbox-headless ($arch): building uncached packages (${#packages[@]}), the job did not finish, see the job log"
		for package in "${packages[@]}"; do
			echo "  $(package_name "$package")"
		done
	} | to_report

	local status=0
	nix build --no-link --keep-going "${packages[@]}" 2>&1 | tee "$TMP_DIR/build.log" >&2 ||
		status=${PIPESTATUS[0]}

	{
		echo "sandbox-headless ($arch): uncached packages built by this check (${#packages[@]})"
		report_builds "$TMP_DIR/build.log" "${packages[@]}"
	} | to_report
	return "$status"
}

main "$@"

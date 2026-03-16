[private]
default:
    @just --list

# symlink build result and write sha256 sidecar
[private]
finalize-image:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p dist
    dir="$(readlink result)"
    image="$(find "$dir" -name '*.qcow2' -print -quit)"
    if [ -z "$image" ]; then
      echo "error: no .qcow2 found in $dir" >&2; exit 1
    fi
    name="$(basename "$image")"
    ln -sfn "$image" "dist/$name"
    if command -v sha256sum &>/dev/null; then
      hash=$(sha256sum "$image" | awk '{print $1}')
    else
      hash=$(shasum -a 256 "$image" | awk '{print $1}')
    fi
    echo "$hash  $name" > "dist/${name%.qcow2}.sha256"
    gpg --detach-sign --armor "dist/${name%.qcow2}.sha256"
    echo "dist/$name (sha256: $hash, signature: ${name%.qcow2}.sha256.asc)"

# build sandbox headless VM image (requires nix)
build-headless arch: && finalize-image
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{arch}}" = "x86_64" ]; then
      nix build .#packages.x86_64-linux.sandbox-headless
    elif [ "{{arch}}" = "aarch64" ]; then
      nix build .#packages.aarch64-linux.sandbox-headless
    else
      echo "error: arch must be x86_64 or aarch64"; exit 1
    fi

# build sandbox GUI VM image (requires nix)
build-gui arch: && finalize-image
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{arch}}" = "x86_64" ]; then
      nix build .#packages.x86_64-linux.sandbox-gui
    elif [ "{{arch}}" = "aarch64" ]; then
      nix build .#packages.aarch64-linux.sandbox-gui
    else
      echo "error: arch must be x86_64 or aarch64"; exit 1
    fi

# pull latest headless image and run
run-headless *ARGS:
    bash scripts/run.sh "$(bash scripts/pull.sh headless)" {{ARGS}}

# pull latest GUI image and run
run-gui *ARGS:
    bash scripts/run.sh "$(bash scripts/pull.sh gui)" {{ARGS}}

# run a local headless image
run-image-headless image *ARGS:
    bash scripts/run.sh {{image}} --headless {{ARGS}}

# run a local GUI image
run-image-gui image *ARGS:
    bash scripts/run.sh {{image}} --gui {{ARGS}}

# pull latest (or specific) VM image
pull variant *ARGS:
    bash scripts/pull.sh {{variant}} {{ARGS}}

# list available image versions
list-images variant="headless":
    bash scripts/pull.sh --list {{variant}}

# ssh into running sandbox
ssh port="2222":
    ssh -p {{port}} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null sandbox@localhost

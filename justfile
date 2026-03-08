[private]
default:
    @just --list

# build sandbox VM image (requires nix)
build arch:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{arch}}" = "x86_64" ]; then
      nixos-rebuild build-image --image-variant qemu --flake .#sandbox
    elif [ "{{arch}}" = "aarch64" ]; then
      nixos-rebuild build-image --image-variant qemu-efi --flake .#sandbox-aarch64
    else
      echo "error: arch must be x86_64 or aarch64"; exit 1
    fi
    ln -sfn "$(readlink result)" "result-sandbox-{{arch}}"

# build sandbox GUI VM image (requires nix)
build-gui arch:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{arch}}" = "x86_64" ]; then
      nixos-rebuild build-image --image-variant qemu --flake .#sandbox-gui
    elif [ "{{arch}}" = "aarch64" ]; then
      nixos-rebuild build-image --image-variant qemu-efi --flake .#sandbox-gui-aarch64
    else
      echo "error: arch must be x86_64 or aarch64"; exit 1
    fi
    ln -sfn "$(readlink result)" "result-sandbox-gui-{{arch}}"

# run sandbox VM (headless)
run image *ARGS:
    bash scripts/run.sh {{image}} {{ARGS}}

# run sandbox GUI VM
run-gui image *ARGS:
    bash scripts/run.sh {{image}} --gui {{ARGS}}

# ssh into running sandbox
ssh port="2222":
    ssh -p {{port}} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null sandbox@localhost

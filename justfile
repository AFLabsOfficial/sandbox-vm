[private]
default:
    @just --list

# build VM image (auto-detects arch, outputs to dist/)
build *ARGS:
    bash scripts/build.sh {{ARGS}}

# sign built images (sha256 + GPG)
sign +images:
    bash scripts/sign.sh {{images}}

# remove build artifacts
clean:
    rm -rf dist/ result result-*

# pull latest headless image and run (--no-pull to use cached)
run-headless *ARGS:
    bash scripts/run.sh --headless {{ARGS}}

# pull latest GUI image and run (--no-pull to use cached)
run-gui *ARGS:
    bash scripts/run.sh --gui {{ARGS}}

# pull latest (or specific) VM image
pull variant *ARGS:
    bash scripts/pull.sh {{variant}} {{ARGS}}

# list available image versions
list-images variant="headless":
    bash scripts/pull.sh --list {{variant}}

# ssh into running sandbox
ssh port="22022" *ARGS:
    ssh -p {{port}} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null {{ARGS}} sandbox@localhost

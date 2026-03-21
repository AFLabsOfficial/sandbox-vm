[private]
default:
    @just --list

# build VM image (auto-detects arch, outputs to dist/)
build *ARGS:
    bash scripts/build.sh {{ARGS}}

# sign a built image (sha256 + GPG)
sign image:
    bash scripts/sign.sh {{image}}

# remove build artifacts
clean:
    rm -rf dist/ result result-*

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
ssh port="2222" *ARGS:
    ssh -p {{port}} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null {{ARGS}} sandbox@localhost

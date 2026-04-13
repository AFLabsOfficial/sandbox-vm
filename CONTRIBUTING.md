# Contributing

## Development

Requires nix with flakes enabled.

```sh
# enter dev shell (provides pre-commit, statix, qemu)
nix develop

# or with direnv
direnv allow

# format
nix fmt

# lint
statix check

# build image
just build x86_64
just build aarch64
```

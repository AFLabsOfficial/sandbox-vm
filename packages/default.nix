{ pkgs }: {
  claude-code = import ./claude-code/package.nix { inherit pkgs; };
}

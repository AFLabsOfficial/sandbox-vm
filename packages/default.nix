{ pkgs }:
{
  claude-code = import ./claude-code/package.nix { inherit pkgs; };
  codex = import ./codex/package.nix { inherit pkgs; };
}

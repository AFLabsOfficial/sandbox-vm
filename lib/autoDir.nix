lib:

# auto-discover nix modules from a directory
# - flat .nix files (excluding default.nix) are imported directly
# - subdirectories containing package.nix are imported via package.nix
dir:
let
  readDir = builtins.readDir dir;

  files = lib.filterAttrs (
    name: type: type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix"
  ) readDir;

  dirs = lib.filterAttrs (
    name: type: type == "directory" && builtins.pathExists (dir + "/${name}/package.nix")
  ) readDir;
in
lib.mapAttrs' (
  name: _: lib.nameValuePair (lib.removeSuffix ".nix" name) (import (dir + "/${name}"))
) files
// lib.mapAttrs (name: _: import (dir + "/${name}/package.nix")) dirs

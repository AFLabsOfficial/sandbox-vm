{ lib }:

let
  autoDir = import ./autoDir.nix lib;
  mapDir = import ./mapDir.nix lib;
in

{
  inherit autoDir mapDir;
}

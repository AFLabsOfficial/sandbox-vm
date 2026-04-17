lib:

let
  autoDir = import ./autoDir.nix lib;
in

dir: args:
let
  attrs = autoDir dir;
in
builtins.mapAttrs (_: f: f args) attrs

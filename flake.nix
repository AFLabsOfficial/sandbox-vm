{
  description = "ephemeral sandbox vm for working with ai";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    claude-code-overlay.url = "github:ryoppippi/claude-code-overlay";
  };

  outputs =
    inputs@{
      nixpkgs,
      ...
    }:

    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      mkSandbox =
        system:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./nix.nix
            ./hosts/sandbox/configuration.nix
            ./modules/nixos/vm-guest.nix
            ./modules/nixos/vm-9p-automount.nix
            ./modules/nixos/seed-ssh.nix
            ./modules/nixos/localisation.nix

            inputs.home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "backup";
              home-manager.users.sandbox = import ./users/sandbox/home-manager.nix;
            }
          ];
          specialArgs = { inherit inputs; };
        };
    in

    {
      nixosConfigurations = {
        sandbox = mkSandbox "x86_64-linux";
        sandbox-aarch64 = mkSandbox "aarch64-linux";
      };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      devShells = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = with nixpkgs.legacyPackages.${system}; [
            pre-commit
            statix
            qemu
            cdrtools
          ];
        };
      });
    };
}

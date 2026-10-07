{
  description = "ephemeral sandbox vm for working with ai";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      nixpkgs,
      ...
    }:

    let
      inherit (nixpkgs) lib;

      version = "v0.11.0";

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;

      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      packagesFor = system: import ./packages { pkgs = pkgsFor system; };

      mkSandbox =
        system:
        lib.nixosSystem {
          inherit system;
          modules = [
            { nixpkgs.config.allowUnfree = true; }
            ./nix.nix
            ./hosts/sandbox/configuration.nix
            ./modules/nixos/vm-guest.nix
            ./modules/nixos/vm-9p-automount.nix
            ./modules/nixos/localisation.nix

            inputs.home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "backup";
              home-manager.users.sandbox = import ./users/sandbox/home-manager.nix;
            }
          ];
          specialArgs = {
            inherit inputs version;
          };
        };

      # build a qcow2 image from a nixos configuration
      mkImage =
        system: format:
        let
          base = mkSandbox system;
          imageModule = base.config.image.modules.${format};
        in
        (base.extendModules { modules = [ imageModule ]; }).config.system.build.image;
    in

    {
      nixosConfigurations = {
        sandbox = mkSandbox "x86_64-linux";
        sandbox-aarch64 = mkSandbox "aarch64-linux";
      };

      packages = forAllSystems (
        system:
        packagesFor system
        // lib.optionalAttrs (system == "x86_64-linux") {
          sandbox-headless = mkImage "x86_64-linux" "qemu";
        }
        // lib.optionalAttrs (system == "aarch64-linux") {
          sandbox-headless = mkImage "aarch64-linux" "qemu-efi";
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      devShells = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = with nixpkgs.legacyPackages.${system}; [
            pre-commit
            statix
            shellcheck
            shfmt
            qemu
          ];
        };
      });
    };
}

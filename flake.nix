{
  description = "ephemeral sandbox vm for working with ai";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    stylix = {
      url = "github:nix-community/stylix";
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

      version = "v0.10.8";

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
        {
          gui ? false,
        }:
        lib.nixosSystem {
          inherit system;
          modules = [
            { nixpkgs.config.allowUnfree = true; }
            { vm-guest.headless = !gui; }
            ./nix.nix
            ./hosts/sandbox/configuration.nix
            ./modules/nixos/vm-guest.nix
            ./modules/nixos/vm-9p-automount.nix
            ./modules/nixos/localisation.nix
            ./modules/nixos/desktop.nix

            inputs.home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "backup";
              home-manager.extraSpecialArgs = { inherit gui; };
              home-manager.users.sandbox = import ./users/sandbox/home-manager.nix;
            }
          ]
          ++ lib.optionals gui [
            inputs.stylix.nixosModules.stylix
            ./modules/nixos/theme.nix
            {
              desktop = {
                enable = true;
                autoLogin = "sandbox";
              };
            }
          ];
          specialArgs = {
            inherit inputs gui version;
          };
        };

      # build a qcow2 image from a nixos configuration
      mkImage =
        system: opts: variant:
        let
          base = mkSandbox system opts;
          imageModule = base.config.image.modules.${variant};
        in
        (base.extendModules { modules = [ imageModule ]; }).config.system.build.image;
    in

    {
      nixosConfigurations = {
        sandbox = mkSandbox "x86_64-linux" { };
        sandbox-aarch64 = mkSandbox "aarch64-linux" { };
        sandbox-gui = mkSandbox "x86_64-linux" { gui = true; };
        sandbox-gui-aarch64 = mkSandbox "aarch64-linux" { gui = true; };
      };

      packages = forAllSystems (
        system:
        packagesFor system
        // lib.optionalAttrs (system == "x86_64-linux") {
          sandbox-headless = mkImage "x86_64-linux" { } "qemu";
          sandbox-gui = mkImage "x86_64-linux" { gui = true; } "qemu";
        }
        // lib.optionalAttrs (system == "aarch64-linux") {
          sandbox-headless = mkImage "aarch64-linux" { } "qemu-efi";
          sandbox-gui = mkImage "aarch64-linux" { gui = true; } "qemu-efi";
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

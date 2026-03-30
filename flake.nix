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

    nixpkgs-master = {
      url = "github:nixos/nixpkgs/master";
      flake = false;
    };
  };

  outputs =
    inputs@{
      nixpkgs,
      ...
    }:

    let
      version = "v0.3.1";

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      mkSandbox =
        system:
        {
          gui ? false,
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            { nixpkgs.config.allowUnfree = true; }
            {
              nixpkgs.overlays = [
                (_: prev: {
                  inherit
                    (import inputs.nixpkgs-master {
                      inherit (prev.stdenv.hostPlatform) system;
                      inherit (prev) config;
                    })
                    claude-code
                    ;
                })
              ];
            }
            ./nix.nix
            ./hosts/sandbox/configuration.nix
            ./modules/nixos/vm-guest.nix
            ./modules/nixos/vm-9p-automount.nix
            ./modules/nixos/seed-ssh.nix
            ./modules/nixos/localisation.nix
            ./modules/nixos/desktop.nix
            ./modules/nixos/theme.nix

            inputs.stylix.nixosModules.stylix

            inputs.home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "backup";
              home-manager.extraSpecialArgs = { inherit gui; };
              home-manager.users.sandbox = import ./users/sandbox/home-manager.nix;
            }
          ]
          ++ nixpkgs.lib.optionals gui [
            {
              vm-guest.headless = nixpkgs.lib.mkForce false;
              desktop = {
                enable = true;
                autoLogin = "sandbox";
              };
              seed-ssh.enable = nixpkgs.lib.mkForce false;
            }
          ];
          specialArgs = {
            inherit inputs;
            inherit gui;
            inherit version;
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

      packages = {
        x86_64-linux = {
          sandbox-headless = mkImage "x86_64-linux" { } "qemu";
          sandbox-gui = mkImage "x86_64-linux" { gui = true; } "qemu";
        };
        aarch64-linux = {
          sandbox-headless = mkImage "aarch64-linux" { } "qemu-efi";
          sandbox-gui = mkImage "aarch64-linux" { gui = true; } "qemu-efi";
        };
      };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      devShells = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = with nixpkgs.legacyPackages.${system}; [
            pre-commit
            statix
            shellcheck
            shfmt
            qemu
            cdrtools
          ];
        };
      });
    };
}

{
  pkgs,
  lib,
  config,
  ...
}:
{

  options = {
    vm-guest = {
      enable = lib.mkEnableOption "VM guest configuration";
      headless = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "run without display, serial console only";
      };
    };
  };

  config = lib.mkIf config.vm-guest.enable {
    services.spice-vdagentd.enable = lib.mkIf (!config.vm-guest.headless) true;

    boot.kernelParams = lib.mkIf config.vm-guest.headless [ "console=ttyS0,115200" ];

    # 9p for host file mounting, autoloaded on first mount
    boot.initrd.availableKernelModules = [
      "9p"
      "9pnet_virtio"
    ];

    # ssh with agent forwarding for git and hot-mount
    services.openssh = {
      enable = true;
      ports = [ 22 ];
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
        AllowAgentForwarding = true;
        StreamLocalBindUnlink = "yes";
      };
    };

    networking = {
      useDHCP = lib.mkDefault true;
      firewall.allowedTCPPorts = [ 22 ];
    };

    security.sudo.wheelNeedsPassword = false;

    # terminfo for ghostty, kitty, alacritty, wezterm, foot, etc. so ssh clients
    # forwarding their native TERM don't break ncurses apps
    environment.enableAllTerminfo = true;

    # FIX:(@janezicmatej) enableAllTerminfo pulls termite.terminfo; termite's
    # vte-ng patch breaks against vte 0.84.0 (vte::to_integral removed upstream).
    # nixpkgs PR #522784 removed termite on 2026-05-23 but nixos-unstable hasn't
    # fast-forwarded past it. drop this stub once the channel catches up.
    nixpkgs.overlays = [
      (_: prev: {
        termite = prev.runCommand "termite-stub" {
          outputs = [
            "out"
            "terminfo"
          ];
        } "mkdir -p $out $terminfo";
      })
    ];

    environment.systemPackages = with pkgs; [
      curl
      wget
      htop
    ];
  };
}

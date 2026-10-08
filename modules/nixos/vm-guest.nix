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
    };
  };

  config = lib.mkIf config.vm-guest.enable {
    # no display, serial console only
    boot.kernelParams = [ "console=ttyS0,115200" ];

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

    environment.systemPackages = with pkgs; [
      curl
      wget
      htop

      # terminfo so ssh clients forwarding their native TERM don't break
      # ncurses apps. ncurses already covers most clients: xterm-256color
      # (terminal.app, iterm2, vs code, windows terminal, gnome terminal,
      # konsole, jetbrains), putty, mintty, alacritty, foot, wezterm, st,
      # tmux, screen and contour. these are the entries
      # environment.enableAllTerminfo installed that it lacks
      #
      # NOTE:(@janezicmatej) not environment.enableAllTerminfo: it installs the
      # terminfo output of every terminal in nixpkgs, which means building the
      # whole terminal whenever hydra failed to, and that broke the image twice
      # (termite with vte 0.84, contour with gcc 16). when one of these breaks
      # the same way, the lockfile gate in release-mr.sh names it
      ghostty.terminfo # xterm-ghostty
      kitty.terminfo # xterm-kitty
      rxvt-unicode-unwrapped.terminfo # rxvt-unicode, rxvt-unicode-256color
      rio.terminfo # xterm-rio
      mtm.terminfo # mtm, mtm-256color
      yaft.terminfo # yaft-256color
    ];
  };
}

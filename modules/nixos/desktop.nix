{
  pkgs,
  lib,
  config,
  ...
}:
{
  options.desktop = {
    enable = lib.mkEnableOption "desktop environment";
    autoLogin = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "user to auto-login as";
    };
  };

  config = lib.mkIf config.desktop.enable {
    services.xserver.enable = true;
    services.desktopManager.budgie.enable = true;
    services.xserver.displayManager.lightdm.enable = true;
    services.displayManager.defaultSession = "budgie-desktop";

    services.displayManager.autoLogin = lib.mkIf (config.desktop.autoLogin != null) {
      enable = true;
      user = config.desktop.autoLogin;
    };

    # audio
    services.pipewire = {
      enable = true;
      pulse.enable = true;
    };

    # trim unused budgie default packages
    environment.budgie.excludePackages = with pkgs; [
      vlc
      gammastep
      grim
      slurp
      swaybg
      swayidle
      wdisplays
      wlopm
    ];

    # disable services not needed in a VM sandbox
    services.printing.enable = lib.mkForce false;
    services.gnome.evolution-data-server.enable = lib.mkForce false;
    services.gnome.gnome-online-accounts.enable = lib.mkForce false;
    services.dleyna.enable = lib.mkForce false;
    services.gnome.rygel.enable = lib.mkForce false;
    services.gnome.gnome-user-share.enable = lib.mkForce false;
    services.geoclue2.enable = lib.mkForce false;
    hardware.bluetooth.enable = lib.mkForce false;

    # use lighter font set instead of noto-fonts
    fonts.enableDefaultPackages = false;
    fonts.packages = [ pkgs.dejavu_fonts ];

    environment.systemPackages = with pkgs; [
      firefox
    ];
  };
}

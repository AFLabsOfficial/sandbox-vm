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
    services.desktopManager.gnome.enable = true;
    services.displayManager.gdm.enable = true;
    services.displayManager.gdm.autoSuspend = false;

    services.displayManager.autoLogin = lib.mkIf (config.desktop.autoLogin != null) {
      enable = true;
      user = config.desktop.autoLogin;
    };

    # audio
    services.pipewire = {
      enable = true;
      pulse.enable = true;
    };

    # trim packages not needed in a VM sandbox
    environment.gnome.excludePackages = with pkgs; [
      epiphany
      gnome-calendar
      gnome-characters
      gnome-clocks
      gnome-contacts
      gnome-font-viewer
      gnome-logs
      gnome-maps
      gnome-music
      gnome-weather
      gnome-connections
      simple-scan
      snapshot
      yelp
      gnome-tour
      gnome-user-docs
      baobab
      decibels
      gnome-calculator
      gnome-system-monitor
      gnome-text-editor
      loupe
      papers
      showtime
    ];

    # disable services not needed in a VM sandbox
    services.printing.enable = lib.mkForce false;
    services.gnome.evolution-data-server.enable = lib.mkForce false;
    services.gnome.gnome-online-accounts.enable = false;
    services.dleyna.enable = false;
    services.gnome.rygel.enable = false;
    services.gnome.gnome-user-share.enable = false;
    services.geoclue2.enable = false;
    hardware.bluetooth.enable = false;

    # use lighter font set instead of noto-fonts
    fonts.enableDefaultPackages = false;
    fonts.packages = [ pkgs.dejavu_fonts ];

    environment.systemPackages = with pkgs; [
      firefox
    ];
  };
}

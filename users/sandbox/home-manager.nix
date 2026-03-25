{
  pkgs,
  lib,
  gui ? false,
  ...
}:
{
  home.stateVersion = "25.11";

  home.packages =
    with pkgs;
    [
      git
      tmux
      ripgrep
      fd
      jq
    ]
    ++ lib.optionals gui [
      gnomeExtensions.dash-to-dock
    ];

  programs.neovim = {
    enable = true;
    vimAlias = true;
    defaultEditor = true;
  };

  dconf = lib.mkIf gui {
    enable = true;
    settings."org/gnome/shell" = {
      enabled-extensions = [
        "dash-to-dock@micxgx.gmail.com"
        "user-theme@gnome-shell-extensions.gcampax.github.com"
      ];
    };
  };
}

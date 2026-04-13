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

  programs.zsh = {
    enable = true;
    dotDir = "/home/sandbox/.config/zsh";
    shellAliases.dsp = "claude --dangerously-skip-permissions";
  };

  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;
      format = "$username$hostname$directory$character";
      hostname = {
        ssh_only = false;
        style = "bold blue";
        format = "[@$hostname]($style)";
      };
      username = {
        show_always = true;
        style_user = "bold blue";
        format = "[$user]($style)";
      };
      directory.format = " [$path]($style) ";
      character = {
        success_symbol = "[>](bold green)";
        error_symbol = "[>](bold red)";
      };
    };
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

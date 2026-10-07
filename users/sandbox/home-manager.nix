{
  pkgs,
  config,
  ...
}:
{
  home.stateVersion = "26.05";

  home.packages = with pkgs; [
    git
    tmux
    ripgrep
    fd
    jq
  ];

  programs.neovim = {
    enable = true;
    vimAlias = true;
    defaultEditor = true;
  };

  programs.zsh = {
    enable = true;
    dotDir = "${config.xdg.configHome}/zsh";
    shellAliases = {
      dsp = "claude --dangerously-skip-permissions";
      dbas = "codex --dangerously-bypass-approvals-and-sandbox";
    };
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
}

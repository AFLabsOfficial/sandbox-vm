{
  pkgs,
  ...
}:
{
  home.stateVersion = "25.11";

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
}

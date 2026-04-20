{
  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      download-buffer-size = 2 * 1024 * 1024 * 1024;
      warn-dirty = false;
    };
  };
}

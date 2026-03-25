{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf config.desktop.enable {
    stylix = {
      enable = true;
      polarity = "dark";
      base16Scheme = "${pkgs.base16-schemes}/share/themes/default-dark.yaml";
      image = "${pkgs.nixos-artwork.wallpapers.nineish-dark-gray}/share/backgrounds/nixos/nix-wallpaper-nineish-dark-gray.png";
    };
  };
}

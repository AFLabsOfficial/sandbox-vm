{
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    autoResize = true;
    fsType = "ext4";
  };

  # image.modules (disk-image.nix) overrides boot loader per variant
  # x86_64: qemu (grub), aarch64: qemu-efi (systemd-boot)
  boot.loader.grub.device = lib.mkDefault "/dev/vda";
}

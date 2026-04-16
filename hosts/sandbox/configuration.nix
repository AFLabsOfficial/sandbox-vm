{
  pkgs,
  lib,
  inputs,
  config,
  gui ? false,
  version ? "unknown",
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "sandbox";

  vm-guest = {
    enable = true;
    headless = true;
  };

  localisation = {
    enable = true;
    timeZone = "UTC";
    defaultLocale = "en_US.UTF-8";
  };

  users.users.sandbox = {
    isNormalUser = true;
    initialPassword = "sandbox";
    shell = pkgs.zsh;
    extraGroups = [
      "wheel"
      "docker"
    ];
  };

  programs.zsh.enable = true;

  vm-9p-automount = {
    enable = true;
    user = "sandbox";
    bindfs = true;
  };

  # ensure .config exists with correct ownership before automount
  systemd.tmpfiles.rules = [ "d /home/sandbox/.config 0755 sandbox users -" ];

  # writable claude config via 9p with bindfs for cross-platform UID compat
  systemd.services.claude-9p-mount = {
    description = "Mount claude config via 9p with bindfs";
    after = [
      "local-fs.target"
      "systemd-modules-load.service"
    ];
    wants = [ "systemd-modules-load.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "claude-9p-mount" ''
        tag=$(find /sys/devices -name mount_tag 2>/dev/null | while read -r f; do
          t=$(tr -d '\0' < "$f")
          [ "$t" = "claude" ] && echo "$t" && break
        done)

        [ -z "$tag" ] && exit 0

        mkdir -p /mnt/9p/claude /home/sandbox/.config/claude
        ${pkgs.util-linux}/bin/mount -t 9p claude /mnt/9p/claude \
          -o trans=virtio,version=9p2000.L || exit 0
        ${pkgs.bindfs}/bin/bindfs \
          --force-user=sandbox --force-group=users \
          /mnt/9p/claude /home/sandbox/.config/claude
      '';
    };
  };

  environment.sessionVariables.CLAUDE_CONFIG_DIR = "/home/sandbox/.config/claude";

  # accept any ssh key (ephemeral localhost-only vm)
  # script lives under /etc/ssh so sshd's parent-directory ownership check passes
  # (/nix/store is group-writable for nixbld, which sshd rejects)
  environment.etc."ssh/accept-key" = {
    mode = "0755";
    text = ''
      #!/bin/sh
      echo "$1 $2"
    '';
  };
  services.openssh.extraConfig = ''
    AuthorizedKeysCommand /etc/ssh/accept-key %t %k
    AuthorizedKeysCommandUser nobody
  '';

  # no hardware firmware needed in a VM
  hardware.enableRedistributableFirmware = lib.mkForce false;
  hardware.wirelessRegulatoryDatabase = lib.mkForce false;

  documentation.enable = false;
  environment.defaultPackages = [ ];

  virtualisation.docker = {
    enable = true;
    logDriver = "json-file";
  };

  environment.systemPackages = with pkgs; [
    claude-code

    # tools
    tmux
    fd
    ripgrep
    jq
    fzf
    just
  ];

  image.modules =
    let
      # sandbox-<variant>-<arch>-<version>-<nixos date.hash>
      # e.g. sandbox-headless-x86_64-0.1.0-20260225.1267bb4
      arch = pkgs.stdenv.hostPlatform.parsed.cpu.name;
      parts = lib.splitString "." config.system.nixos.version;
      date = builtins.elemAt parts 2;
      hash = builtins.elemAt parts 3;
      variant = if gui then "gui" else "headless";
      name = "sandbox-${variant}-${arch}-${version}-${date}.${hash}";
    in
    let
      imageOverride =
        { config, modulesPath, ... }:
        {
          image.baseName = name;
          system.build.image = lib.mkForce (
            import (modulesPath + "/../lib/make-disk-image.nix") {
              inherit lib config pkgs;
              inherit (config.virtualisation) diskSize;
              inherit (config.image) baseName;
              format = "qcow2-compressed";
              partitionTableType = if config.image.efiSupport then "efi" else "legacy";
            }
          );
        };
    in
    {
      qemu = imageOverride;
      qemu-efi = imageOverride;
    };

  system.stateVersion = "25.11";
}

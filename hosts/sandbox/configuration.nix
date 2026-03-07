{
  pkgs,
  lib,
  inputs,
  config,
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

  seed-ssh = {
    enable = true;
    user = "sandbox";
  };

  localisation = {
    enable = true;
    timeZone = "UTC";
    defaultLocale = "en_US.UTF-8";
  };

  users.users.sandbox = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "docker"
    ];
  };

  vm-9p-automount = {
    enable = true;
    user = "sandbox";
    bindfs = true;
  };

  # writable claude config via 9p with bindfs for macOS UID compat
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

        mkdir -p /mnt/9p/claude /home/sandbox/.claude
        ${pkgs.util-linux}/bin/mount -t 9p claude /mnt/9p/claude \
          -o trans=virtio,version=9p2000.L || exit 0
        ${pkgs.bindfs}/bin/bindfs \
          --force-user=sandbox --force-group=users \
          /mnt/9p/claude /home/sandbox/.claude
        chown sandbox:users /home/sandbox/.claude
      '';
    };
  };

  # .claude.json passed via qemu fw_cfg
  boot.kernelModules = [ "qemu_fw_cfg" ];
  systemd.services.claude-json = {
    after = [ "systemd-modules-load.service" ];
    wants = [ "systemd-modules-load.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "claude-json" ''
        src="/sys/firmware/qemu_fw_cfg/by_name/opt/claude.json/raw"
        [ -f "$src" ] || exit 0
        cp "$src" /home/sandbox/.claude.json
        chown sandbox:users /home/sandbox/.claude.json
      '';
    };
  };

  virtualisation.docker = {
    enable = true;
    logDriver = "json-file";
  };

  environment.systemPackages = with pkgs; [
    inputs.claude-code-overlay.packages.${pkgs.stdenv.hostPlatform.system}.default

    # tools
    tmux
    fd
    ripgrep
    jq
    fzf
    just
  ];

  # image builder VM needs more than the default 1G to copy closure
  image.modules =
    let
      # sandbox-<nixos date.hash>-<arch> (e.g. sandbox-20260225.1267bb4-x86_64)
      arch = pkgs.stdenv.hostPlatform.parsed.cpu.name;
      parts = lib.splitString "." config.system.nixos.version;
      date = builtins.elemAt parts 2;
      hash = builtins.elemAt parts 3;
      name = "sandbox-${date}.${hash}-${arch}";

      imageMemOverride =
        { config, modulesPath, ... }:
        {
          image.baseName = name;
          system.build.image = lib.mkForce (
            import (modulesPath + "/../lib/make-disk-image.nix") {
              inherit lib config pkgs;
              inherit (config.virtualisation) diskSize;
              inherit (config.image) baseName format;
              partitionTableType = if config.image.efiSupport then "efi" else "legacy";
              memSize = 16384;
            }
          );
        };
    in
    {
      qemu = imageMemOverride;
      qemu-efi = imageMemOverride;
    };

  system.stateVersion = "25.11";
}

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
    # pinned so the 9p automount can detect whether host uids match guest
    uid = 1000;
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
  };

  # ensure .config exists with correct ownership before automount
  systemd.tmpfiles.rules = [ "d /home/sandbox/.config 0755 sandbox users -" ];

  # writable claude config via 9p, direct when host uids match, bindfs fallback otherwise
  systemd.services.claude-9p-mount = {
    description = "Mount claude config via 9p";
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
        have_tag=0
        for tagfile in $(find /sys/devices -name mount_tag 2>/dev/null); do
          [ -f "$tagfile" ] || continue
          t=$(tr -d '\0' < "$tagfile")
          if [ "$t" = "claude" ]; then
            have_tag=1
            break
          fi
        done
        [ "$have_tag" = "1" ] || exit 0

        exec ${config.vm-9p-automount.mountShareScript} claude /home/sandbox/.config/claude
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

  documentation = {
    enable = false;
    man.enable = false;
    info.enable = false;
    doc.enable = false;
    nixos.enable = false;
  };
  environment.defaultPackages = [ ];

  virtualisation.docker = {
    enable = true;
    logDriver = "json-file";
  };

  environment.systemPackages = [
    inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.claude-code
  ]
  ++ (with pkgs; [
    # tools
    tmux
    fd
    ripgrep
    jq
    fzf
    just
  ]);

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
            let
              rawImage = import (modulesPath + "/../lib/make-disk-image.nix") {
                inherit lib config pkgs;
                inherit (config.virtualisation) diskSize;
                inherit (config.image) baseName;
                format = "qcow2";
                partitionTableType = if config.image.efiSupport then "efi" else "legacy";
              };
            in
            # post-process: parallel zstd on qcow2 v3 (~half the size of zlib v2, faster decompress)
            pkgs.runCommand name { nativeBuildInputs = [ pkgs.qemu-utils ]; } ''
              mkdir -p $out
              # qemu-img caps -m at 16
              cores="''${NIX_BUILD_CORES:-4}"
              [ "$cores" -gt 0 ] || cores=4
              [ "$cores" -gt 16 ] && cores=16
              qemu-img convert \
                -f qcow2 \
                -O qcow2 \
                -c \
                -o compression_type=zstd \
                -m "$cores" \
                ${rawImage}/${name}.qcow2 \
                $out/${name}.qcow2
            ''
          );
        };
    in
    {
      qemu = imageOverride;
      qemu-efi = imageOverride;
    };

  system.stateVersion = "25.11";
}

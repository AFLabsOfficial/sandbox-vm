{
  pkgs,
  lib,
  config,
  ...
}:
{
  options = {
    seed-ssh = {
      enable = lib.mkEnableOption "SSH key injection from seed ISO";

      user = lib.mkOption {
        type = lib.types.str;
        description = "user to install authorized_keys for";
      };

      label = lib.mkOption {
        type = lib.types.str;
        default = "SEEDCONFIG";
        description = "volume label of the seed ISO";
      };
    };
  };

  config = lib.mkIf config.seed-ssh.enable {
    systemd.services.seed-ssh = {
      description = "Install SSH authorized_keys from seed ISO";
      after = [
        "local-fs.target"
        "nss-user-lookup.target"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart =
          let
            cfg = config.seed-ssh;
            inherit (cfg) user;
            inherit (config.users.users.${user}) home group;
          in
          pkgs.writeShellScript "seed-ssh" ''
            # try by-label first, then scan block devices for the volume label
            DEVICE="/dev/disk/by-label/${cfg.label}"
            if [ ! -e "$DEVICE" ]; then
              DEVICE=$(${pkgs.util-linux}/bin/blkid -t LABEL="${cfg.label}" -o device | head -1)
            fi

            if [ -z "$DEVICE" ] || [ ! -e "$DEVICE" ]; then
              echo "seed ISO not found, skipping"
              exit 0
            fi

            MOUNT=$(mktemp -d)
            ${pkgs.util-linux}/bin/mount -o ro "$DEVICE" "$MOUNT"

            mkdir -p "${home}/.ssh"
            cp "$MOUNT/authorized_keys" "${home}/.ssh/authorized_keys"
            chmod 700 "${home}/.ssh"
            chmod 600 "${home}/.ssh/authorized_keys"
            chown -R ${user}:${group} "${home}/.ssh"

            ${pkgs.util-linux}/bin/umount "$MOUNT"
            rmdir "$MOUNT"
          '';
      };
    };
  };
}

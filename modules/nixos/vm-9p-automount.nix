{
  pkgs,
  lib,
  config,
  ...
}:
let
  inherit (config.vm-9p-automount) user;
  inherit (config.users.users.${user}) home group;
in
{
  options = {
    vm-9p-automount = {
      enable = lib.mkEnableOption "auto-discover and mount 9p shares";

      user = lib.mkOption {
        type = lib.types.str;
        description = "user to own the mount points";
      };

      prefix = lib.mkOption {
        type = lib.types.str;
        default = "mount_";
        description = "9p mount tag prefix to match";
      };

      basePath = lib.mkOption {
        type = lib.types.str;
        default = "${home}/mnt";
        description = "directory to mount shares under";
      };

      bindfs = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "remap ownership via bindfs for cross-platform UID compatibility";
      };
    };
  };

  config = lib.mkIf config.vm-9p-automount.enable {
    environment.systemPackages = lib.mkIf config.vm-9p-automount.bindfs [ pkgs.bindfs ];

    systemd.services.vm-9p-automount = {
      description = "Auto-discover and mount 9p shares";
      after = [
        "local-fs.target"
        "nss-user-lookup.target"
        "systemd-modules-load.service"
      ];
      wants = [ "systemd-modules-load.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "vm-9p-automount" (
          if config.vm-9p-automount.bindfs then
            ''
              BASE="${config.vm-9p-automount.basePath}"
              PREFIX="${config.vm-9p-automount.prefix}"
              STAGING="/mnt/9p"
              mkdir -p "$BASE" "$STAGING"
              chown ${user}:${group} "$BASE"

              for tagfile in $(find /sys/devices -name mount_tag 2>/dev/null); do
                [ -f "$tagfile" ] || continue
                tag=$(tr -d '\0' < "$tagfile")

                case "$tag" in
                  "$PREFIX"*) ;;
                  *) continue ;;
                esac

                name="''${tag#"$PREFIX"}"
                staging="$STAGING/$name"
                target="$BASE/$name"

                mkdir -p "$staging" "$target"
                ${pkgs.util-linux}/bin/mount -t 9p "$tag" "$staging" \
                  -o trans=virtio,version=9p2000.L || continue
                ${pkgs.bindfs}/bin/bindfs \
                  --force-user=${user} --force-group=${group} \
                  "$staging" "$target"
              done
            ''
          else
            ''
              BASE="${config.vm-9p-automount.basePath}"
              PREFIX="${config.vm-9p-automount.prefix}"
              mkdir -p "$BASE"
              chown ${user}:${group} "$BASE"

              for tagfile in $(find /sys/devices -name mount_tag 2>/dev/null); do
                [ -f "$tagfile" ] || continue
                tag=$(tr -d '\0' < "$tagfile")

                case "$tag" in
                  "$PREFIX"*) ;;
                  *) continue ;;
                esac

                name="''${tag#"$PREFIX"}"
                target="$BASE/$name"

                mkdir -p "$target"
                ${pkgs.util-linux}/bin/mount -t 9p "$tag" "$target" \
                  -o trans=virtio,version=9p2000.L || continue
              done
            ''
        );
      };
    };
  };
}

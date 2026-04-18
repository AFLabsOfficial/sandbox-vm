{
  pkgs,
  lib,
  config,
  ...
}:
let
  inherit (config.vm-9p-automount) user;
  userCfg = config.users.users.${user};
  inherit (userCfg) home group;

  mountShareScript = pkgs.writeShellScript "mount-9p-share" ''
    # usage: mount-9p-share <tag> <target>
    # mounts to a staging dir, probes uid, then either mount --moves
    # into place (uid match) or bindfs-remaps onto target (mismatch)
    set -u
    TAG="$1"
    TARGET="$2"
    STAGING_BASE="/mnt/9p"
    EXPECTED_UID="${toString userCfg.uid}"

    log() { echo "9p[$TAG]: $*" >&2; }

    if ${pkgs.util-linux}/bin/mountpoint -q "$TARGET"; then
      log "already mounted at $TARGET, skipping"
      exit 0
    fi

    mkdir -p "$TARGET" "$STAGING_BASE"
    staging="$STAGING_BASE/$TAG"
    mkdir -p "$staging"

    if ! ${pkgs.util-linux}/bin/mountpoint -q "$staging"; then
      if ! ${pkgs.util-linux}/bin/mount -t 9p "$TAG" "$staging" \
          -o trans=virtio,version=9p2000.L; then
        log "9p mount failed (tag not shared by host?)"
        exit 1
      fi
    fi

    owner=$(${pkgs.coreutils}/bin/stat -c %u "$staging" 2>/dev/null || echo "")
    if [ "$owner" = "$EXPECTED_UID" ]; then
      if ! ${pkgs.util-linux}/bin/mount --move "$staging" "$TARGET"; then
        log "mount --move $staging -> $TARGET failed"
        ${pkgs.util-linux}/bin/umount "$staging" || true
        exit 1
      fi
    else
      log "uid $owner != $EXPECTED_UID, remapping via bindfs"
      if ! ${pkgs.bindfs}/bin/bindfs \
          --force-user=${user} --force-group=${group} \
          "$staging" "$TARGET"; then
        log "bindfs $staging -> $TARGET failed"
        ${pkgs.util-linux}/bin/umount "$staging" || true
        exit 1
      fi
    fi
  '';
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
        default = "m_";
        description = "9p mount tag prefix to match";
      };

      basePath = lib.mkOption {
        type = lib.types.str;
        default = "${home}/mnt";
        description = "directory to mount shares under";
      };

      mountShareScript = lib.mkOption {
        type = lib.types.package;
        internal = true;
        description = "shared helper that probes uid and mounts a 9p share with bindfs fallback";
      };
    };
  };

  config = lib.mkIf config.vm-9p-automount.enable {
    assertions = [
      {
        assertion = userCfg.uid != null;
        message = "vm-9p-automount requires users.users.${user}.uid to be set so UID-match detection is stable";
      }
    ];

    # bindfs is only used as a fallback when the host UID does not match the guest user (e.g. macos)
    environment.systemPackages = [ pkgs.bindfs ];

    vm-9p-automount.mountShareScript = mountShareScript;

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
        ExecStart = pkgs.writeShellScript "vm-9p-automount" ''
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
            ${mountShareScript} "$tag" "$BASE/$name" || true
          done
        '';
      };
    };
  };
}

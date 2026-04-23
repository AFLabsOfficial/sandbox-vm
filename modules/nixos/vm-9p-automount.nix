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
    # mount 9p directly at target; if the host uid doesn't match the guest
    # user, remount via a bindfs staging dir to remap ownership.
    # NOTE:(@janezicmatej) we avoid `mount --move` because sources under a
    # shared parent (systemd default for /) can't be moved
    set -u
    TAG="$1"
    TARGET="$2"
    EXPECTED_UID="${toString userCfg.uid}"

    log() { echo "9p[$TAG]: $*" >&2; }

    if ${pkgs.util-linux}/bin/mountpoint -q "$TARGET"; then
      log "already mounted at $TARGET, skipping"
      exit 0
    fi

    mkdir -p "$TARGET"

    if ! ${pkgs.util-linux}/bin/mount -t 9p "$TAG" "$TARGET" \
        -o trans=virtio,version=9p2000.L; then
      log "9p mount failed (tag not shared by host?)"
      exit 1
    fi

    owner=$(${pkgs.coreutils}/bin/stat -c %u "$TARGET" 2>/dev/null || echo "")
    if [ "$owner" = "$EXPECTED_UID" ]; then
      exit 0
    fi

    log "uid $owner != $EXPECTED_UID, remapping via bindfs"
    ${pkgs.util-linux}/bin/umount "$TARGET"

    # staging holds the raw pre-remap 9p mount; lock it down so a second
    # user on the guest can't read through it to the host fs
    mkdir -p /mnt/9p
    chmod 700 /mnt/9p
    staging="/mnt/9p/$TAG"
    mkdir -p "$staging"
    chmod 700 "$staging"
    if ! ${pkgs.util-linux}/bin/mountpoint -q "$staging"; then
      if ! ${pkgs.util-linux}/bin/mount -t 9p "$TAG" "$staging" \
          -o trans=virtio,version=9p2000.L; then
        log "9p restage mount failed"
        exit 1
      fi
    fi

    if ! ${pkgs.bindfs}/bin/bindfs \
        --force-user=${user} --force-group=${group} \
        "$staging" "$TARGET"; then
      log "bindfs $staging -> $TARGET failed"
      ${pkgs.util-linux}/bin/umount "$staging" || true
      exit 1
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

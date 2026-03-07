{
  lib,
  config,
  ...
}:
{
  options = {
    localisation = {
      enable = lib.mkEnableOption "localisation defaults";

      timeZone = lib.mkOption {
        type = lib.types.str;
      };

      defaultLocale = lib.mkOption {
        type = lib.types.str;
      };
    };
  };

  config = lib.mkIf config.localisation.enable {
    time.timeZone = config.localisation.timeZone;
    i18n.defaultLocale = config.localisation.defaultLocale;

    # NOTE:(@janezicmatej) some apps (e.g. java) need TZ env var explicitly
    environment.variables.TZ = config.localisation.timeZone;
  };
}

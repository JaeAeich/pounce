# launchd agents that start Pounce at login, plus optional declarative config.
# `self` is the flake, used to default `package` to this flake's build.
self:

let
  common =
    { lib, pkgs, ... }:
    {
      options.services.pounce = {
        enable = lib.mkEnableOption "Pounce keyboard navigation";
        package = lib.mkOption {
          type = lib.types.package;
          default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
          defaultText = lib.literalExpression "pounce.packages.\${system}.default";
          description = "Pounce package to run.";
        };
        settings = lib.mkOption {
          type = (pkgs.formats.toml { }).type;
          default = { };
          example = lib.literalExpression ''
            {
              shortcuts.hint = "hyper+f";
              hints = { alphabet = "asdfjkl"; theme = "dark"; labels_only = true; };
              general = { hyper_key = true; ignored_apps = [ "com.valvesoftware.steam" ]; };
              apps."com.google.Chrome".scan = "exhaustive";
            }
          '';
          description = ''
            Pounce config (see `pounce config show` for every key). When non-empty the config
            is managed by Nix and the Settings window becomes read-only.
          '';
        };
      };
    };

  program = cfg: "${cfg.package}/Applications/Pounce.app/Contents/MacOS/Pounce";
  configFile = pkgs: cfg: (pkgs.formats.toml { }).generate "pounce-config.toml" cfg.settings;
  agent = pkgs: cfg: {
    ProgramArguments = [ (program cfg) ];
    RunAtLoad = true;
    KeepAlive = true;
    ProcessType = "Interactive";
    # POUNCE_LAUNCHD tells the app it's already started at login (greys out its own login-item toggle).
    EnvironmentVariables = {
      POUNCE_LAUNCHD = "1";
    }
    // (if cfg.settings == { } then { } else { POUNCE_CONFIG = "${configFile pkgs cfg}"; });
  };
in
{
  darwin =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.pounce;
    in
    {
      imports = [ common ];
      config = lib.mkIf cfg.enable {
        environment.systemPackages = [ cfg.package ];
        launchd.user.agents.pounce.serviceConfig = agent pkgs cfg;
      };
    };

  homeManager =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.pounce;
    in
    {
      imports = [ common ];
      config = lib.mkIf cfg.enable {
        home.packages = [ cfg.package ];
        # Also link it to the default location so `pounce config check` etc. see it.
        xdg.configFile."pounce/config.toml" = lib.mkIf (cfg.settings != { }) {
          source = configFile pkgs cfg;
        };
        launchd.agents.pounce = {
          enable = true;
          config = agent pkgs cfg;
        };
      };
    };
}

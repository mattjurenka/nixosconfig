# A screen that dims and warms as the day goes, and a bar glyph with a dropdown
# of four modes to override it.
#
# The obvious way to build this is to read an ambient light sensor, and this
# laptop has none: no /sys/bus/iio device, no ACPI0008, and although `amd_sfh`
# is loaded it is only there as an `amd_pmf` dependency -- the AMD sensor
# fusion hub's MP2 endpoint (1022:164a/15e4) is absent from the bus, so the HP
# OmniBook 5 simply does not have the part fitted. Firmware-side auto
# brightness is out too; amd-pmf reports "No Smart PC policy present".
#
# So the input is the sun's position, computed from my.location. It cannot tell
# a dim room from a bright one at the same hour, which a sensor could -- what it
# can do is be right about the thing that drives room light most of the time,
# with no hardware and no camera watching the person. The presets in the
# dropdown exist because that proxy will sometimes be wrong.
#
# The work is split along the line of what noctalia already does well:
#
#   colour warmth  -> noctalia's own night light (see noctalia.nix). It holds a
#                     wlr-gamma-control client and ramps between two colour
#                     temperatures over an hour either side of sunset, anchored
#                     to the wall clock rather than to when the shell started.
#                     A second gamma client here would only fight it, and its
#                     own `nightlight` bar widget sits beside this one's glyph
#                     because the forced state it shows lives only in that
#                     running service and is never written to the config.
#   brightness     -> the service below, because noctalia's [brightness]
#                     section configures the backend it reaches the panel
#                     through and has no schedule of its own.
{ ... }: {
  flake.modules.homeManager.adaptiveDisplay = { pkgs, lib, config, ... }:
    let
      cfg = config.my.adaptiveDisplay;
      noctaliaPackage = config.programs.noctalia.package;

      # Named once here because three places have to agree on them: the
      # directory home-manager links the generated plugin into, the IPC call
      # that tells noctalia to look there, and the IPC calls that enable the
      # plugin found inside. A disagreement between them is invisible -- see
      # reloadPlugin for why noctalia reports it as success.
      pluginDirName = "noctalia-plugins-brightness";
      sourceName = "brightness";
      pluginId = "jurenka/brightness-modes";

      # Named by the widget and worth having on PATH, so a mode can be set or
      # watched from a shell as well as from the bar.
      displayMode = pkgs.writeShellApplication {
        name = "display-mode";
        runtimeInputs = [ pkgs.inotify-tools pkgs.coreutils ];
        bashOptions = [ "nounset" "pipefail" ];
        text = builtins.readFile ./adaptive-display/display-mode.sh;
      };

      sunBrightness = pkgs.writeShellApplication {
        name = "sun-brightness";
        runtimeInputs = [ pkgs.gawk pkgs.coreutils pkgs.systemd pkgs.inotify-tools ];
        # No errexit: a refused SetBrightness on an inactive session is an
        # expected tick outcome, not a reason to take the loop down.
        bashOptions = [ "nounset" "pipefail" ];
        text = builtins.replaceStrings
          [
            "@latitude@"
            "@longitude@"
            "@dayBrightness@"
            "@nightBrightness@"
            "@minBrightness@"
            "@dayElevation@"
            "@nightElevation@"
            "@intervalSeconds@"
          ]
          [
            (toString config.my.location.latitude)
            (toString config.my.location.longitude)
            (toString cfg.dayBrightness)
            (toString cfg.nightBrightness)
            (toString cfg.minBrightness)
            (toString cfg.dayElevation)
            (toString cfg.nightElevation)
            (toString cfg.intervalSeconds)
          ]
          (builtins.readFile ./adaptive-display/sun-brightness.sh);
      };

      # noctalia installs plugins out of a source directory holding a catalog
      # and one subdirectory per plugin. Generated rather than committed as-is
      # so the widget can name the mode helper by its store path instead of
      # hoping for a PATH -- a bar widget does not get the session's one.
      #
      # A source of its own rather than an addition to claude-status's: a
      # source has exactly one catalog, and two features merging into one
      # directory would couple them for nothing.
      pluginSource = pkgs.runCommand "noctalia-brightness-modes-plugin" { } ''
        mkdir -p "$out/brightness-modes"
        cp ${./adaptive-display/plugin/catalog.toml} "$out/catalog.toml"
        cp ${./adaptive-display/plugin/brightness-modes/plugin.toml} "$out/brightness-modes/plugin.toml"
        substitute ${./adaptive-display/plugin/brightness-modes/buttons.luau} \
          "$out/brightness-modes/buttons.luau" \
          --replace-fail '@mode@' '${lib.getExe displayMode}'
        # The dropdown the widget opens. Same substitution, because both halves
        # name the same mode command: the widget to follow it, the panel to set
        # it.
        substitute ${./adaptive-display/plugin/brightness-modes/panel.luau} \
          "$out/brightness-modes/panel.luau" \
          --replace-fail '@mode@' '${lib.getExe displayMode}'
      '';

      # Registers the source and (re-)exports the plugin into the running shell.
      #
      # Both halves have to happen over IPC rather than in noctalia-config.toml,
      # because noctalia's runtime settings.toml carries its own `[plugins]`
      # block and it shadows the declarative file's completely: a source named
      # only in config.toml is never discovered, and the plugin never appears.
      # Nothing says so either -- `plugins enable` answers "ok (exporting in
      # background)" for a plugin it has never heard of -- so the only symptom
      # is a widget that is quietly absent from the bar. Hence the check at the
      # end: this unit should go red rather than let that happen silently again.
      #
      # The re-export matters on its own too. noctalia copies a plugin out of
      # its source directory when it is enabled, so a rebuilt widget never
      # reaches a shell that already has the old copy; disabling first is what
      # makes it pick the new one up. The source path is named in the script on
      # purpose, so that it changes with every new build of the plugin, which is
      # what makes systemd run this again -- and what keeps it idle on a rebuild
      # that changed nothing here.
      reloadPlugin = pkgs.writeShellApplication {
        name = "brightness-modes-plugin-reload";
        runtimeInputs = [ noctaliaPackage pkgs.coreutils ];
        bashOptions = [ "nounset" "pipefail" ];
        text = ''
          echo "source is ${pluginSource}"

          # `plugins source list` is the readiness probe: it only answers once
          # the shell's IPC socket is up, which graphical-session.target being
          # reached does not guarantee.
          for _ in $(seq 20); do
            if noctalia msg plugins source list >/dev/null 2>&1; then
              # Idempotent: a source is keyed by name, so this replaces rather
              # than duplicates.
              #
              # The tilde is meant to stay unexpanded, which is what the
              # suppression below is for. noctalia stores a source location
              # verbatim and does its own expansion, and the sources already in
              # settings.toml are written this way; passing $HOME would bake an
              # absolute path for one user into the shell's own state.
              # shellcheck disable=SC2088
              noctalia msg plugins source add ${sourceName} path '~/.config/${pluginDirName}' >/dev/null 2>&1 || true

              noctalia msg plugins disable ${pluginId} >/dev/null 2>&1 || true
              noctalia msg plugins enable ${pluginId} >/dev/null 2>&1 || true

              # The export is asynchronous and `enable` would have said "ok"
              # whatever happened, so looking is the only honest check.
              for _ in $(seq 10); do
                if noctalia msg plugins list 2>/dev/null \
                    | grep -q '^${pluginId} .* enabled'; then
                  echo "${pluginId} is enabled"
                  exit 0
                fi
                sleep 1
              done

              echo "${pluginId} did not come up; noctalia lists:" >&2
              noctalia msg plugins list >&2 2>&1 || true
              exit 1
            fi
            sleep 1
          done

          echo "noctalia's IPC never answered; the widget will be missing" >&2
          exit 1
        '';
      };
    in
    {
      options.my.adaptiveDisplay = {
        enable = lib.mkEnableOption "a backlight that follows the sun" // {
          default = true;
        };

        dayBrightness = lib.mkOption {
          type = lib.types.float;
          default = 1.0;
          description = ''
            Backlight level once the sun is well up, as a fraction of the
            panel's raw range.
          '';
        };

        nightBrightness = lib.mkOption {
          type = lib.types.float;
          default = 0.05;
          description = ''
            Backlight level after dark.

            This started at 0.35 on the reasoning that the panel declares
            `scale = non-linear` in sysfs while noctalia maps its own 0..1 onto
            the raw range linearly regardless, so the raw midpoint sits well
            below half the *perceived* brightness and a value picked as though
            the scale were linear would come out punishingly dark. Tried in a
            dark room, that reasoning was simply wrong about where the floor of
            comfortable is: 0.35 is glaring at night.

            Note that at the default this is equal to
            <option>minBrightness</option>, which is both the "minimum" preset
            and the floor under everything the service writes. Two consequences:
            the minimum button has nothing left to do once the curve has
            bottomed out, and a manual nudge below 5% at night gets pulled back
            up to 5% on the next tick. Lower
            <option>minBrightness</option> if you want headroom under the curve.
          '';
        };

        minBrightness = lib.mkOption {
          type = lib.types.float;
          default = 0.05;
          description = ''
            The floor under everything this writes, and the level the "minimum"
            preset button asks for.

            Deliberately above zero: a 0 here is a black screen whose only way
            back is the thing that just set it.
          '';
        };

        dayElevation = lib.mkOption {
          type = lib.types.float;
          default = 10.0;
          description = ''
            Solar elevation, in degrees above the horizon, at which
            <option>dayBrightness</option> is reached.
          '';
        };

        nightElevation = lib.mkOption {
          type = lib.types.float;
          default = -6.0;
          description = ''
            Solar elevation at which <option>nightBrightness</option> is
            reached.

            The default is civil twilight: the sun is below the horizon but the
            sky is not black yet, which is about when a screen at full
            brightness starts to hurt.
          '';
        };

        intervalSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = 60;
          description = ''
            Seconds between ticks of the curve. This is not how often the
            backlight moves -- a tick only writes when its target has drifted
            more than a percent from where the panel already is, so the flat
            middle of the day and of the night cost one read of sysfs a minute
            and nothing else. A button press does not wait for a tick either;
            the service watches the mode file and wakes on it.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        # Both worth having on PATH. Run the service's script in a terminal and
        # it prints the sun's elevation and the curve's verdict on every tick,
        # which is the whole story when the screen is at a brightness that
        # seems wrong.
        home.packages = [ sunBrightness displayMode ];

        # Where reloadPlugin points noctalia with `plugins source add`.
        xdg.configFile.${pluginDirName}.source = pluginSource;

        systemd.user.services.sun-brightness = {
          Unit = {
            Description = "Backlight that follows the sun";
            # Tied to the graphical session for the same reason noctalia is:
            # logind only honours SetBrightness for an active seat session, and
            # the shell that should stay in step with the result is only up
            # inside one.
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
          };

          Service = {
            ExecStart = lib.getExe sunBrightness;
            # on-failure, not always: the script exits 0 on a host with no
            # sysfs backlight, and that is a final answer rather than something
            # to retry every few seconds forever.
            Restart = "on-failure";
            RestartSec = 10;
          };

          Install.WantedBy = [ "graphical-session.target" ];
        };

        systemd.user.services.brightness-modes-plugin-reload = {
          Unit = {
            Description = "Hand a rebuilt brightness modes widget to the running shell";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
          };

          Service = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe reloadPlugin;
            # The unit now fails rather than shrugging when the plugin does not
            # come up, so give it a way out of a shell that was merely slow to
            # start listening.
            Restart = "on-failure";
            RestartSec = 10;
          };

          Install.WantedBy = [ "graphical-session.target" ];
        };
      };
    };
}

# A day that is planned before it is spent.
#
# The problem this is for: the hours go to YouTube and Steam because nothing
# ever says what the alternative was. So the Claude calendar becomes the only
# statement of what the day is for, Claude writes it there each morning after
# agreeing it, and this machine reads it back three ways -- a notification at
# every block start, a line in the bar saying what is running and how much of
# it is left, and a gate that closes YouTube, Twitch, Reddit and Steam windows
# until a plan exists.
#
# What makes the gate work is that it is not a timer: the calendar carries an
# event titled "✅ Plan approved" that Claude creates at the moment the plan is
# agreed, running to the end of the day. There is nothing to wait out, and
# wake-up time is whatever it turns out to be -- planning is triggered by
# saying "plan my day", not by a clock. The one escape hatch is `dayplan skip`,
# which opens the gate for the day and writes a line to skips.log; a gate with
# no way out is a gate that gets deleted from this file at 8am.
#
# The day rolls over at 4am rather than at midnight, so a session that runs
# past midnight is still working under the plan it was given, and the gate
# shuts again while he is asleep rather than mid-sentence.
#
# Three parts live here: the tool (dayplan.py, standard library only), the
# noctalia bar widget and its dropdown, and the planning procedure as a Claude
# skill. The phone half is a list of settings to click through on a Samsung and
# so cannot be declared -- it is in dayplan/phone-setup.md.
#
# This is a home-manager aspect rather than a NixOS one for the same reason
# claude-status is: everything it touches is one user's session -- their
# compositor socket, their notification daemon, their shell's bar, their
# ~/.config -- and the credential it reads must not go near the store.
{ ... }:
{
  flake.modules.homeManager.dayplan = { pkgs, lib, config, ... }:
    let
      cfg = config.my.dayplan;

      # Named once because three places have to agree on them: the directory
      # home-manager links the generated plugin into, the IPC call that points
      # noctalia at it, and the calls that enable what is found there. See
      # reloadPlugin for why a disagreement between them is silent.
      pluginDirName = "noctalia-plugins-dayplan";
      sourceName = "dayplan";
      pluginId = "jurenka/dayplan";

      # The options are camelCase because that is what a Nix module looks like
      # and the script's keys are snake_case because that is what Python looks
      # like, so the translation happens once, here, rather than as a
      # dictionary either side has to keep. Anything not named is left at
      # DEFAULTS in dayplan.py -- the tick and sync intervals, the approval
      # prefix, the notification lead -- because nothing has wanted them
      # changed per host.
      settingsFile = pkgs.writeText "dayplan-config.json" (builtins.toJSON {
        timezone = cfg.timezone;
        calendar_id = cfg.calendarId;
        day_starts_hour = cfg.dayStartsHour;
        planning_url = cfg.planningUrl;
        gate_enabled = cfg.gate.enable;
        blocked_app_ids = cfg.gate.blockedAppIds;
        blocked_titles = cfg.gate.blockedTitles;
        title_scope_app_ids = cfg.gate.titleScopeAppIds;
        max_cache_age_minutes = cfg.gate.maxCacheAgeMinutes;
      });

      # niri, notify-send and xdg-open are named by store path rather than left
      # to PATH on purpose: the two callers that matter are a systemd user unit
      # and a noctalia widget, and neither of them gets the login shell's
      # environment.
      dayplan = pkgs.writeShellApplication {
        name = "dayplan";
        runtimeInputs = [ pkgs.niri pkgs.libnotify pkgs.xdg-utils ];
        bashOptions = [ "nounset" "pipefail" ];
        text = ''
          exec ${lib.getExe pkgs.python3} ${./dayplan/dayplan.py} "$@"
        '';
      };

      # noctalia installs plugins out of a source directory holding a catalog
      # and one subdirectory per plugin. Generated rather than committed as-is
      # so the widget can name the tool by its store path -- a bar widget does
      # not get the session's PATH. A source of its own rather than an addition
      # to claude-status's: a source has exactly one catalog, and two features
      # merging into one directory would couple them for nothing.
      pluginSource = pkgs.runCommand "noctalia-dayplan-plugin" { } ''
        mkdir -p "$out/dayplan"
        cp ${./dayplan/plugin/catalog.toml} "$out/catalog.toml"
        cp ${./dayplan/plugin/dayplan/plugin.toml} "$out/dayplan/plugin.toml"
        substitute ${./dayplan/plugin/dayplan/block.luau} "$out/dayplan/block.luau" \
          --replace-fail '@dayplan@' '${lib.getExe dayplan}'
        substitute ${./dayplan/plugin/dayplan/today.luau} "$out/dayplan/today.luau" \
          --replace-fail '@dayplan@' '${lib.getExe dayplan}' \
          --replace-fail '@open@' '${lib.getExe' pkgs.xdg-utils "xdg-open"}' \
          --replace-fail '@planningUrl@' '${cfg.planningUrl}'
      '';

      # Registers the source and (re-)exports the plugin into the running
      # shell. Both halves have to happen over IPC rather than in
      # noctalia-config.toml, because noctalia's runtime settings.toml carries
      # its own `[plugins]` block that shadows the declarative file's
      # completely: a source named only in config.toml is never discovered, the
      # plugin never appears, and nothing says so -- `plugins enable` answers
      # "ok (exporting in background)" for a plugin it has never heard of.
      # Hence the check at the end: this unit goes red rather than leaving a
      # widget quietly absent from the bar.
      #
      # The re-export matters on its own too. noctalia copies a plugin out of
      # its source when it is enabled, so a rebuilt widget never reaches a
      # shell that already has the old copy; disabling first is what makes it
      # pick the new one up. The source path is named in the script so that it
      # changes with every new build of the plugin, which is what makes systemd
      # run this again -- and what keeps it idle on a rebuild that changed
      # nothing here.
      reloadPlugin = pkgs.writeShellApplication {
        name = "dayplan-plugin-reload";
        runtimeInputs = [ config.programs.noctalia.package pkgs.coreutils pkgs.gnugrep ];
        bashOptions = [ "nounset" "pipefail" ];
        text = ''
          echo "source is ${pluginSource}"

          # `plugins source list` is the readiness probe: it only answers once
          # the shell's IPC socket is up, which graphical-session.target being
          # reached does not guarantee.
          for _ in $(seq 20); do
            if noctalia msg plugins source list >/dev/null 2>&1; then
              # Idempotent: a source is keyed by name, so this replaces rather
              # than duplicates. The tilde is meant to stay unexpanded --
              # noctalia stores a location verbatim and does its own expansion,
              # and passing $HOME would bake one user's absolute path into the
              # shell's own state.
              # shellcheck disable=SC2088
              noctalia msg plugins source add ${sourceName} path '~/.config/${pluginDirName}' >/dev/null 2>&1 || true

              noctalia msg plugins disable ${pluginId} >/dev/null 2>&1 || true
              noctalia msg plugins enable ${pluginId} >/dev/null 2>&1 || true

              # The export is asynchronous and `enable` would have said "ok"
              # whatever happened, so looking is the only honest check.
              for _ in $(seq 10); do
                if noctalia msg plugins list 2>/dev/null | grep -q '^${pluginId} .* enabled'; then
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
      options.my.dayplan = {
        calendarId = lib.mkOption {
          type = lib.types.str;
          default = "d4d3457c1699083d464ecbfc9817359e17534ad8c8056a346aed1d35db5f6633@group.calendar.google.com";
          description = ''
            The calendar Claude writes the plan to, and the only source of
            truth about the day. Shared with noctalia's own calendar widget,
            which reads the same id -- see noctalia-config.toml.

            Only used by the Calendar API backend. The secret iCal address
            names its own calendar, so this is ignored when that is what is
            configured.
          '';
        };

        timezone = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "America/Phoenix";
          description = ''
            The zone the plan's hours mean. Pinned rather than left to the
            machine's clock because a laptop travels and a plan does not: a
            block agreed as "2pm, after class" means 2pm where the class is.

            null to follow the system clock instead.
          '';
        };

        dayStartsHour = lib.mkOption {
          type = lib.types.ints.between 0 12;
          default = 4;
          description = ''
            When one plan's day ends and the next begins. Deliberately not
            midnight: a block that runs to 1am belongs to the day it was
            planned on, and the gate should shut again while he is asleep
            rather than in the middle of the evening's last block.
          '';
        };

        planningUrl = lib.mkOption {
          type = lib.types.str;
          default = "https://claude.ai/new";
          description = ''
            Opened once a day, the first time the gate has to close something,
            and by the "Plan with Claude" button in the bar dropdown. The web
            app rather than a local Claude Code session because the same
            conversation has to be reachable from the phone.
          '';
        };

        gate = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Whether to close the blocked windows while the day has no
              approved plan. Off leaves everything else -- the notifications,
              the bar line, the dropdown -- exactly as it was, which is the
              setting to try first if the gate turns out to be the wrong amount
              of friction.
            '';
          };

          blockedAppIds = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "^steam$" "^steam_app_[0-9]+" "^steamwebhelper$" "^lutris$" ];
            description = ''
              Case-insensitive regexes matched against a window's `app_id`.
              Check a candidate against `niri msg windows` first: Steam's own
              windows are `steam`, a running game is `steam_app_<appid>`.

              Closing a Steam window leaves Steam itself in the tray, so this
              is friction rather than a hard block -- which is the intended
              amount.
            '';
          };

          blockedTitles = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "youtube" "twitch" "reddit" "netflix" ];
            description = ''
              Case-insensitive regexes matched against the title of a window
              whose `app_id` is in <option>titleScopeAppIds</option>.

              This is how a site is caught, since every tab of a browser
              shares one `app_id` (`chromium-browser` here) and the title is
              the only handle on which tab is in front. Enforcement is driven
              by niri's event stream rather than by the daemon's tick for
              exactly this reason: opening YouTube in a new tab of an existing
              window makes the title say so for about three seconds, and a
              20-second sweep caught that roughly one time in eight.

              It does mean the whole window goes, with its other tabs.
              Ctrl+Shift+T brings them back. Nothing outside the browser can
              close a single tab.
            '';
          };

          titleScopeAppIds = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "chrom" "firefox" "librewolf" "brave" "\\bzen\\b" "epiphany" ];
            description = ''
              Which windows a <option>blockedTitles</option> rule may judge.

              A title means a website only inside a browser. Anywhere else
              "youtube" is as likely to be a file open in an editor or an
              argument in a shell, and since the gate now acts on a window
              event rather than on a 20-second tick, a false positive closes
              that editor the instant the file is opened.

              `chrom` covers both `chromium-browser` and the
              `chrome-<hash>-Default` windows an installed PWA gets.
            '';
          };

          maxCacheAgeMinutes = lib.mkOption {
            type = lib.types.ints.positive;
            default = 45;
            description = ''
              How stale the cached calendar may be before the gate stops
              closing windows.

              A morning with no network is not a morning without a plan, and
              being locked out of your own laptop by a dead wifi link is the
              one failure this must not have. The gate still reports itself as
              open-because-stale, so the bar says why.
            '';
          };
        };
      };

      # No `enable` option: in this tree a feature is on because a host
      # imported it.
      config = {
        # On PATH because every one of these is worth running by hand:
        # `dayplan today` when the bar looks wrong, `dayplan sync` after
        # approving a plan, `dayplan skip` when the day is not going to be
        # planned, `dayplan auth` once at setup.
        home.packages = [ dayplan ];

        xdg.configFile."dayplan/config.json".source = settingsFile;

        # Where reloadPlugin points noctalia with `plugins source add`.
        xdg.configFile.${pluginDirName}.source = pluginSource;

        # The planning procedure, as a skill Claude Code picks up from any
        # project on this machine. The claude.ai half of it -- which is where
        # the phone plans from, and the only side with the Google Calendar
        # connector -- has to be uploaded by hand; the file is the same one.
        home.file.".claude/skills/plan-my-day/SKILL.md".source = ./dayplan/plan-my-day/SKILL.md;

        systemd.user.services.dayplan = {
          Unit = {
            Description = "dayplan: block notifications and the morning gate";
            # Tied to the graphical session because two of the three things it
            # does need one: niri's socket to find and close a window, and a
            # notification daemon to tell him a block has started. niri's
            # systemd session exports NIRI_SOCKET and WAYLAND_DISPLAY into the
            # user manager, which is what makes `niri msg` work in here.
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
          };

          Service = {
            ExecStart = "${lib.getExe dayplan} daemon";
            # always rather than on-failure: the loop exits only on something
            # it could not handle, and a day watched by nothing is the failure
            # mode worth avoiding.
            Restart = "always";
            RestartSec = 10;
          };

          Install.WantedBy = [ "graphical-session.target" ];
        };

        systemd.user.services.dayplan-plugin-reload = {
          Unit = {
            Description = "Hand a rebuilt dayplan widget to the running shell";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
          };

          Service = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe reloadPlugin;
            # A way out of a shell that was merely slow to start listening.
            Restart = "on-failure";
            RestartSec = 10;
          };

          Install.WantedBy = [ "graphical-session.target" ];
        };
      };
    };
}

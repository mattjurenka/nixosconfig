# Mod+T switches the touchpad off and on, and a glyph in the bar says which.
#
# The switch is the kernel's `inhibited` attribute on the touchpad's input
# nodes (touchpad/touchpad.sh says why not niri). The NixOS half lets this
# user write it; the home half is the command, the bar widget and the reload
# that hands the widget to the running shell. The bind is in niri.nix with the
# rest, and the widget's place in the bar in noctalia-config.toml.
{ ... }: {
  flake.modules.nixos.touchpad = { pkgs, ... }:
    let
      # Every node of the pad's HID device, for the reason touchpad.sh gives.
      # The "Mouse" sibling registers before the "Touchpad" node, so by the
      # time this runs for the latter, both are there to be found.
      grant = pkgs.writeShellScript "touchpad-grant" ''
        for f in "$1"/../input*/inhibited; do
          ${pkgs.coreutils}/bin/chgrp users "$f"
          ${pkgs.coreutils}/bin/chmod g+w "$f"
        done
      '';
    in
    {
      # Not just "add": `udevadm trigger` replays devices as "change", which is
      # how a pad that was already there when the rule arrived gets it.
      services.udev.extraRules = ''
        ACTION!="remove", SUBSYSTEM=="input", KERNEL=="input*", ENV{ID_INPUT_TOUCHPAD}=="1", RUN+="${grant} /sys%p"
      '';
    };

  flake.modules.homeManager.touchpad = { pkgs, lib, config, ... }:
    let
      noctaliaPackage = config.programs.noctalia.package;

      # Same three-way agreement as in adaptive-display.nix.
      pluginDirName = "noctalia-plugins-touchpad";
      sourceName = "touchpad";
      pluginId = "jurenka/touchpad";

      touchpad = pkgs.writeShellApplication {
        name = "touchpad";
        runtimeInputs = [ pkgs.inotify-tools pkgs.coreutils pkgs.gnugrep pkgs.systemd ];
        bashOptions = [ "nounset" "pipefail" ];
        text = builtins.readFile ./touchpad/touchpad.sh;
      };

      pluginSource = pkgs.runCommand "noctalia-touchpad-plugin" { } ''
        mkdir -p "$out/touchpad"
        cp ${./touchpad/plugin/catalog.toml} "$out/catalog.toml"
        cp ${./touchpad/plugin/touchpad/plugin.toml} "$out/touchpad/plugin.toml"
        substitute ${./touchpad/plugin/touchpad/indicator.luau} \
          "$out/touchpad/indicator.luau" \
          --replace-fail '@touchpad@' '${lib.getExe touchpad}'
      '';

      # brightness-modes-plugin-reload in adaptive-display.nix, for this
      # plugin; the reasoning there holds here word for word.
      reloadPlugin = pkgs.writeShellApplication {
        name = "touchpad-plugin-reload";
        runtimeInputs = [ noctaliaPackage pkgs.coreutils pkgs.gnugrep ];
        bashOptions = [ "nounset" "pipefail" ];
        text = ''
          echo "source is ${pluginSource}"

          for _ in $(seq 20); do
            if noctalia msg plugins source list >/dev/null 2>&1; then
              # shellcheck disable=SC2088
              noctalia msg plugins source add ${sourceName} path '~/.config/${pluginDirName}' >/dev/null 2>&1 || true

              noctalia msg plugins disable ${pluginId} >/dev/null 2>&1 || true
              noctalia msg plugins enable ${pluginId} >/dev/null 2>&1 || true

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
      # On PATH for the niri bind, which names it rather than a store path for
      # the same reason voice-ptt does.
      home.packages = [ touchpad ];

      xdg.configFile.${pluginDirName}.source = pluginSource;

      systemd.user.services.touchpad-plugin-reload = {
        Unit = {
          Description = "Hand a rebuilt touchpad widget to the running shell";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };

        Service = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe reloadPlugin;
          Restart = "on-failure";
          RestartSec = 10;
        };

        Install.WantedBy = [ "graphical-session.target" ];
      };
    };
}

# lagwatch: a once-a-second record of what the machine was waiting on, for
# stutters that are over by the time anyone looks (lagwatch/lagwatch.py).
#
# Added 2026-10-30 for omni-laptop's spikes -- audio carries on, noctalia and
# clicks lag. The first look found three suspects at once and no way to tell
# them apart: the NVMe pinned at 100% busy on 15 MB/s (nix evaluating the
# fleet) with I/O "full" pressure near 50%; Steam's CHTTPClientThread taking
# bursts of bus-lock traps every few minutes; and zram 96% full, which is
# where the Oct 10 freeze (omni-laptop/configuration.nix) started. So: record
# first, mark the lag when it happens (Mod+Ctrl+L, in niri.nix), read
# `lagwatch report` afterwards.
#
# A root service because only root can read every cgroup's I/O and every
# process's counters; the log is world-readable in /var/log/lagwatch, three
# days of it at roughly 10 MB a day.
{ ... }: {
  flake.modules.nixos.lagwatch = { pkgs, ... }:
    let
      lagwatch = pkgs.writers.writePython3Bin "lagwatch" {
        flakeIgnore = [ "E501" "E731" ];
        makeWrapperArgs = [
          "--prefix" "PATH" ":" (pkgs.lib.makeBinPath [ pkgs.util-linux pkgs.libnotify pkgs.systemd ])
        ];
      } (builtins.readFile ./lagwatch/lagwatch.py);
    in {
      environment.systemPackages = [ lagwatch ];

      systemd.services.lagwatch = {
        description = "Once-a-second record of stalls, disk and swap, for lagwatch report";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${lagwatch}/bin/lagwatch record";
          Restart = "always";
          LogsDirectory = "lagwatch";
          LogsDirectoryMode = "0755";
          # The recorder has to run through the stalls it is recording; a gap
          # (dt) is still a reading, but a resident recorder gives better ones.
          Nice = -5;
          MemoryMin = "64M";
          CPUWeight = 1000;
          IOWeight = 1000;
        };
      };
    };
}

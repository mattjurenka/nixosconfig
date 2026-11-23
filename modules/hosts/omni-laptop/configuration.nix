{ self, inputs, ... }: {
  flake.modules.nixos.omniLaptopConfiguration = { pkgs, config, ... }: {
    # corkboard's counters: resctrl mounted, for the fleet view's RAM
    # bandwidth, and the most the Ryzen's memory can move. The fleet module
    # brings them too; they're one module, and stay if the laptop stops
    # being a fleet host.
    imports = [ self.modules.nixos.omniLaptopHardware inputs.corkboard.nixosModules.counters ];

    # Radeon 840M integrated graphics (AMD Ryzen AI 7 445): mesa/amdgpu needs
    # nothing beyond the `hardware.graphics` base in workstation.nix.

    # Use the systemd-boot EFI boot loader.
    boot.loader = {
      systemd-boot = {
        enable = true;
      };
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/boot";
      };
    };

    # Xiaomi Mi USB Receiver Mouse: 1200 DPI in hardware, scaled down to
    # my.mouse.targetDpi (800) so it matches every other mouse.
    my.mouse.hardwareDpi = 1200;

    # Reclaim headroom, added 2026-10-11 with my.agentVms.instances.brain-vm's
    # `memoryMax`. The cgroup ceiling there is what stops a runaway guest from
    # taking the host; these three are what make the near-miss survivable,
    # because the freeze was never an out-of-memory *kill* -- it was the
    # absence of one.
    #
    # hardware.nix has `swapDevices = [ ]`, which on a 22.5 GiB box running a
    # 12 GiB VM means anonymous memory has nowhere to go. The kernel's only
    # reclaim target is then page cache, so under pressure it evicts the
    # file-backed text of niri, libinput and everything else, faults it
    # straight back, and never declares OOM because that reclaim keeps
    # "succeeding". The screen stays lit and the cursor keeps moving on the
    # amdgpu cursor plane while every input path waits minutes on a major
    # fault -- which is precisely what Oct 10 looked like, including twelve
    # `libinput: your system is too slow` stalls of up to 4.1s and a logrotate
    # that spent 52ms of CPU over 2.854s of wall clock reading 112 MB back off
    # disk.
    #
    # zram rather than a swap file or partition: the root filesystem is on
    # LUKS, so disk swap would mean encrypting every page on the way out and
    # back, and the pages being evicted here are mostly QEMU's guest RAM,
    # which compresses well. It is a reclaim target, not capacity -- it exists
    # so pressure degrades into slowness that recovers.
    zramSwap = {
      enable = true;
      algorithm = "zstd";
      memoryPercent = 25;
    };

    boot.kernel.sysctl = {
      # Start reclaiming far earlier and in bigger batches. The default 10
      # (0.1% of memory) sets watermarks that a VM faulting in guest pages
      # blows through between kswapd wakeups, which is how the slow,
      # unkillable spiral gets entered in the first place; 200 (2%) gives
      # kswapd ~450 MB of runway on this machine to reclaim in the background
      # instead of every allocation stalling in direct reclaim.
      "vm.watermark_scale_factor" = 200;

      # zram is RAM, so paging to it is cheap compared with evicting an
      # executable page that then has to come back off an encrypted NVMe.
      # Prefer swapping anonymous memory over dropping the host's text.
      "vm.swappiness" = 180;

      # Matches the above: zram reads cost no seek, so the readahead the
      # default assumes is a disk optimisation that just wastes decompression.
      "vm.page-cluster" = 0;
    };

    # Encrypt and decrypt inline instead of through dm-crypt's kworker
    # queues, added 2026-11-02. Those queues date from spinning disks, where
    # a scheduling hop was free next to a seek; on this NVMe they are a real
    # share of the latency. On Nov 2 a Steam install (65 GB staged) held io
    # pressure at 77% full with writes averaging ~48ms and jbd2 in D state,
    # and every interactive write queued behind Steam's in the same kworkers.
    # AES-NI makes the inline crypto cheap. This does not make the drive
    # faster under sustained writes; it removes the wait in front of it.
    boot.initrd.luks.devices."luks-cb727517-8ea5-46e0-b2dd-293480555332".bypassWorkqueues = true;

    # Keep the session's own pages off the reclaim menu. Even with the ceiling
    # above, the compositor is the process whose stalls *are* the symptom --
    # 2G of memory.min means niri, libinput and the bar stay resident while
    # anything else is squeezed, so a loaded machine stays steerable and the
    # VM can still be stopped by hand.
    systemd.slices.user.sliceConfig.MemoryMin = "2G";

    # The browser VM: a tap device, the host-side firewall rules it cannot
    # reach, and its drop box. Its guest is nixosConfigurations.claude-vm.
    # Spawned agents' VMs are corkboard's (services.corkboard.fleet, in
    # modules/features/corkboard.nix).
    my.agentVms = {
      instances = {
        # The browser: its job is the web, so it gets the public internet (and
        # nothing on this LAN). Started by hand with `claude-vm`.
        claude-vm.egress = "open";

        # brain-vm (the work brain) and pepper-vm (Pepper, which runs on the
        # droplet now) were removed 2026-10-31 at Matt's request; their
        # disks are still in /var/lib/{brain-vm,pepper-vm}, their plans in
        # ../../features/agent-vm/plan.nix, and their history in git.
      };
    };

    # NetworkManager resets Wi-Fi power saving on every connect, so re-apply
    # the charger-based setting (see ac-power-switch below).
    networking.networkmanager.dispatcherScripts = [{
      source = pkgs.writeShellScript "ac-power-switch-on-connect" ''
        [ "$2" = "up" ] && ${pkgs.systemd}/bin/systemctl start --no-block ac-power-switch.service
        exit 0
      '';
    }];
    networking.hostName = "omni-laptop";

    # Claude Desktop's Cowork tab opens /dev/vhost-vsock to reach the VM it
    # runs tasks in, and only this group may -- see
    # modules/features/claude-desktop.nix. Takes a fresh login, not just a
    # switch. The rest of Matt's groups are in workstation.nix.
    users.users.matthew.extraGroups = [ "kvm" ];

    # On charger: performance profile + Wi-Fi power saving off (it adds ping spikes).
    # On battery: balanced profile + Wi-Fi power saving on.
    systemd.services.ac-power-switch = {
      description = "Switch power profile and Wi-Fi power saving on charger state";
      after = [ "power-profiles-daemon.service" ];
      wants = [ "power-profiles-daemon.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ config.services.power-profiles-daemon.package pkgs.iw ];
      serviceConfig.Type = "oneshot";
      script = ''
        if [ "$(cat /sys/class/power_supply/ACAD/online)" = 1 ]; then
          profile=performance; wifi_ps=off
        else
          profile=balanced; wifi_ps=on
        fi
        powerprofilesctl set "$profile"
        for dev in /sys/class/net/*/wireless; do
          [ -e "$dev" ] || continue
          iw dev "$(basename "$(dirname "$dev")")" set power_save "$wifi_ps" || true
        done
      '';
    };
    services.udev.extraRules = ''
      SUBSYSTEM=="power_supply", KERNEL=="ACAD", RUN+="${pkgs.systemd}/bin/systemctl start --no-block ac-power-switch.service"
    '';

    system.stateVersion = "26.05";
  };
}

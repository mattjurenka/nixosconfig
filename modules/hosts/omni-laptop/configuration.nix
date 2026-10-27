{ self, ... }: {
  flake.modules.nixos.omniLaptopConfiguration = { pkgs, config, ... }: {
    imports = [ self.modules.nixos.omniLaptopHardware ];

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

    # Keep the session's own pages off the reclaim menu. Even with the ceiling
    # above, the compositor is the process whose stalls *are* the symptom --
    # 2G of memory.min means niri, libinput and the bar stay resident while
    # anything else is squeezed, so a loaded machine stays steerable and the
    # VM can still be stopped by hand.
    systemd.slices.user.sliceConfig.MemoryMin = "2G";

    # Isolated agent VMs: tap devices, the host-side firewall rules the guests
    # cannot reach, and the read-only drop boxes they share. The guests
    # themselves are nixosConfigurations.claude-vm and .brain-vm.
    my.agentVms = {
      instances = {
        # The browser: its job is the web, so it gets the public internet (and
        # nothing on this LAN). Started by hand with `claude-vm`.
        claude-vm.egress = "open";

        # The second brain: headless and always-on. Open egress since
        # 2026-10-11, at Matt's instruction, after the trade was laid out.
        #
        # What this gives up, written down because it was the architecture's
        # main remaining control rather than a detail. This guest holds a Graph
        # token over the whole Stable mailbox, two GitHub PATs with write, and a
        # full-account Google refresh token including send-as. The allowlist was
        # the only thing addressing the exfiltration leg -- VM isolation never
        # touched it, which ~/second-brain/.agent/plans/second-brain-prd.md says
        # at length -- so a prompt injection that reaches the agent can now
        # reach the internet holding those credentials. What is left is
        # `sanitize.py` and the heartbeat's pre-flight guardrail, and both are
        # best-effort judgement rather than a boundary.
        #
        # Why anyway: the brain is being asked to build the repos it has been
        # able to read since 2026-10-10, and a nix flake over a pnpm workspace
        # needs cache.nixos.org, codeload.github.com and registry.npmjs.org at
        # minimum. Discovering that list one refused host at a time was costing
        # more than the control was returning at this stage of the build.
        #
        # Reverting is `egress = "allowlist"` plus the domain list this change
        # deletes. Recover it from this commit's parent, or from
        # ~/brain-vm-open-egress.patch, which applies in reverse.
        #
        # Three things had to go with it, none of them optional:
        #
        #   routedEgress (the Steam hole). An assertion in
        #     ~/corkboard/fleet/host/host.nix refuses it on an open
        #     instance, and is right to: every public address is already
        #     reachable, so the exception would read as a restriction while
        #     granting nothing. Steam now takes the ordinary route.
        #
        #   The guest's resolver. dnsmasq on the gateway is `mkIf (routed !=
        #     {})` and the port-53 accept is conditioned the same way, so both
        #     disappear with the hole -- while the guest still said
        #     `nameservers = [ hostAddress ]`. That combination is a guest with
        #     a route to the whole internet and no way to resolve any of it.
        #     modules/hosts/brain-vm now uses public resolvers, as claude-vm
        #     already did.
        #
        #   The guest's HTTP_PROXY/HTTPS_PROXY environment. tinyproxy is
        #     `mkIf (allowlisted != {})` and brain-vm was the only allowlisted
        #     instance, so the proxy is gone; leaving those variables set would
        #     point every proxy-aware tool -- curl, git, gh, httpx, Claude Code
        #     -- at a dead port, and the open guest would have reached strictly
        #     less than the closed one.
        brain-vm = {
          egress = "open";

          headless = true;

          # The guest owns its filesystem, as of 2026-10-14. A real NixOS
          # install on its own GPT disk -- its own ESP, its own systemd-boot,
          # `/nix/store` a directory on its own ext4 root -- instead of the
          # arrangement that was here before, where the host rebuilt an erofs
          # store image from its own evaluation on every launch and the guest's
          # store was an overlay on top of it.
          #
          # This is the half of the claim the host is responsible for: the
          # launcher refuses to start without a disk rather than creating a
          # bootless one, the firmware's variable store gets a stable path, and
          # `brain-vm-install-disk` and `brain-vm-migrate-disk` exist. The other
          # half is in modules/hosts/brain-vm/configuration.nix and the two have
          # to agree -- see the option's description for what that means.
          #
          # Why it was worth doing: the overlay made nix unreliable in the one
          # guest that needed nix most. One SQLite database described two layers
          # with two owners, the host's layer was thrown away and rebuilt, and
          # the guest's half outlived it -- so after a host rebuild the database
          # named paths that were gone, and nix believed the database. That is
          # the 2026-10-13 `nix shell nixpkgs#awscli2` failure, and the cure was
          # a thing a person had to know. It is now simply a machine.
          #
          # What it gives up: this VM no longer shares the host's store, so what
          # it builds, it builds on six vCPU and downloads for itself. Given
          # that a compile in the *host's* nix-daemon is what took this laptop
          # down on 2026-10-13, moving those builds behind the cgroup ceiling
          # below is the direction they should have been going anyway.
          ownsDisk = true;

          # SSH into the guest, added 2026-10-16. The three consoles below were
          # a ceiling, not a comfort: one chardev serves one client, the
          # always-on `claude` session holds one of them for hours, and asking
          # for a fourth shell meant raising a number and rebuilding the host.
          # `brain-vm-ssh` is as many sessions as are wanted over the address
          # the guest already has, with a pty -- so Claude Code gets the real
          # window size instead of the 80x24 `fit` has to work around.
          #
          # The guest half of the claim is services.openssh in
          # modules/hosts/brain-vm/configuration.nix, listening on its tap
          # address only, keys only, with
          # modules/hosts/brain-vm/authorized-keys naming who may log in. No
          # firewall rule changed for it on either side; see the option.
          sshLogin = true;

          # The ceiling, added 2026-10-11 after two hard freezes the evening
          # the Valheim client landed (boots -1 and -2 of Oct 10, both ending
          # mid-journal with no shutdown sequence). This cgroup had peaked at
          # 18.79 GiB of the machine's 22.5, with `swapDevices = [ ]` and no
          # limit of any kind, so the host had nothing left to reclaim but the
          # text pages of its own compositor.
          #
          # 14336 puts the derived MemoryHigh at 13312. That was ~800 MiB above
          # what the guest plus QEMU's own overhead cost when the guest asked
          # for 12288; since ./gpu.nix it sits ~2.5 GiB above a 10240 MiB guest,
          # and the difference is not slack -- it is the GPU's. A guest buffer
          # allocated through the virtio-gpu's host memory window is host memory
          # charged to QEMU, inside this ceiling but outside the guest's `-m`,
          # so a texture set Valheim loads is spent here rather than there.
          # Lowering the guest's own figure is what paid for it; this number did
          # not move, which is the point -- the host's protection is unchanged.
          #
          # So the throttle point is still reached by this VM's *page cache* --
          # the store image and the virtiofs traffic, both re-readable -- and
          # that is what gets squeezed, rather than the host's text. The
          # remaining 1 GiB to the wall is only crossed by a guest that is
          # genuinely runaway, and then QEMU is what dies.
          #
          # Same scheduling constraint as claude-vm, and now for the same
          # reason stated in one place: with this at 14336 the host keeps
          # ~8 GiB, which is a desktop session *or* Steam on the host, not both
          # alongside the guest. Both freezes had host Steam running.
          memoryMax = 14336;
          # virtiofsd needs its sources to exist before the VM starts.
          extraDirs = [
            "/home/matthew/second-brain"
            "/home/matthew/second-brain/vault"
            # Read-only into the guest so it can read Stable's code. These
            # already exist; listed so virtiofsd never starts against a
            # missing source.
            "/home/matthew/stable-monorepo"
            "/home/matthew/stable-accounts"
            # Added 2026-10-10: Matt corrected the scope -- these are Stable
            # work, not personal projects, so the brain can read their source.
            # verse is in his own GitHub namespace and in scope anyway; who
            # owns a repo is not the same question as whose work it is.
            "/home/matthew/baum-monorepo"
            "/home/matthew/baum-docs"
            "/home/matthew/verse"
            "/home/matthew/nancy-tracker-onchain"
          ];
        };

        # Pepper, the personal assistant (~/pepper/.agent/plans/pepper-prd.md),
        # added 2026-10-24. Headless and allowlisted; the list is the pepper
        # brain's egress, written down with its reasons in
        # modules/features/fleet.nix.
        pepper-vm = {
          egress = "allowlist";
          allowedDomains = self.lib.fleet.templates.pepper-vm.egress;

          headless = true;
          sshLogin = true;

          # The guest asks for 1536 MiB; this leaves QEMU's own overhead and
          # the store image's page cache room under the ceiling. Small next
          # to brain-vm's 14336, but always on alongside it, so it comes out
          # of what the host keeps.
          memoryMax = 2048;
        };
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

    # For CS2: renders at a lower res inside a native-res fullscreen window,
    # and owns mouse input so XWayland pointer warping doesn't fight the aim.
    programs.gamescope.enable = true;
    # Launch with `gamemoderun` to switch to performance power settings while in-game.
    programs.gamemode.enable = true;

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

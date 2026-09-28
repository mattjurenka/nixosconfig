{ self, ... }: {
  # Address plan and paths for the isolated browser VM, shared between the
  # host-side plumbing below and the guest in modules/hosts/claude-vm, so the
  # two can never drift apart.
  flake.lib.claudeVm = rec {
    # A plain tap device rather than QEMU's default user-mode (SLiRP) stack.
    # SLiRP maps 10.0.2.2 straight onto the host's loopback, which would hand
    # the guest every service bound on 127.0.0.1, and there is no SLiRP option
    # to turn that off without also killing internet access.
    interface = "clvm0";
    prefixLength = 24;
    hostAddress = "10.77.0.1";
    guestAddress = "10.77.0.2";
    subnet = "10.77.0.0/${toString prefixLength}";
    mac = "52:54:00:c1:a0:02";

    stateDir = "/var/lib/claude-vm";
    shareDir = "${stateDir}/share";
    diskImage = "${stateDir}/disk.qcow2";
    spiceSocket = "${stateDir}/spice.sock";
    runDir = "${stateDir}/run";
  };

  flake.nixosModules.claudeVmHost = { pkgs, lib, config, ... }:
    let
      vm = self.lib.claudeVm;
      cfg = config.my.claudeVm;

      # Everything the guest is not allowed to do is expressed here, on the
      # host, in its own table. A rogue guest can rewrite its own firewall all
      # it likes; it cannot reach these rules.
      rules = pkgs.writeText "claude-vm.nft" ''
        # Idempotent reload: declare, delete, then define for real.
        table inet claude-vm {}
        delete table inet claude-vm

        table inet claude-vm {
          chain input {
            type filter hook input priority -10; policy accept;

            # The guest has no business talking to this machine at all. It
            # boots with a static address and a public resolver, so it needs
            # neither DHCP nor DNS from us. Dropping here also covers the
            # gateway address ${vm.hostAddress}, which is the only address of
            # ours it can even see. ARP is a separate family and still
            # resolves, so routing through us keeps working.
            iifname "${vm.interface}" counter drop
          }

          chain forward {
            type filter hook forward priority -10; policy accept;

            # Replies to connections the guest opened, and nothing else
            # inbound: no other machine can reach into the VM.
            oifname "${vm.interface}" ct state established,related counter accept
            oifname "${vm.interface}" counter drop

            # Outbound: the public internet only. Everything private is
            # off-limits, which covers this laptop's LAN address, the router,
            # anything else on the same network, and link-local.
            iifname "${vm.interface}" ip daddr {
              10.0.0.0/8,
              100.64.0.0/10,
              127.0.0.0/8,
              169.254.0.0/16,
              172.16.0.0/12,
              192.168.0.0/16
            } counter drop
            iifname "${vm.interface}" ip6 daddr {
              ::1,
              fe80::/10,
              fc00::/7
            } counter drop

            iifname "${vm.interface}" counter accept
          }

          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            ip saddr ${vm.subnet} oifname != "${vm.interface}" counter masquerade
          }
        }
      '';

      # The VM has no window of its own: it renders to a SPICE socket, and
      # pixels only exist while a viewer is attached.
      viewer = pkgs.writeShellApplication {
        name = "claude-vm-view";
        runtimeInputs = [ pkgs.virt-viewer ];
        text = ''
          if [ ! -S ${vm.spiceSocket} ]; then
            echo "claude-vm does not appear to be running: no socket at ${vm.spiceSocket}" >&2
            exit 1
          fi
          exec remote-viewer "spice+unix://${vm.spiceSocket}" "$@"
        '';
      };

      launcher = pkgs.writeShellApplication {
        name = "claude-vm";
        runtimeInputs = [ config.nix.package ];
        text = ''
          # Reusing one directory keeps each launch from leaving a multi-GB
          # Nix store image behind in /tmp.
          export TMPDIR=${vm.runDir}
          export USE_TMPDIR=1
          mkdir -p "$TMPDIR"

          # Stale socket from a VM that was killed rather than shut down.
          rm -f ${vm.spiceSocket}

          runner=$(nix build --no-link --print-out-paths \
            "${cfg.flake}#nixosConfigurations.claude-vm.config.system.build.vm")
          exec "$runner"/bin/run-claude-vm-vm "$@"
        '';
      };
    in
    {
      options.my.claudeVm = {
        enable = lib.mkEnableOption "the isolated Claude browser VM's host-side plumbing";

        owner = lib.mkOption {
          type = lib.types.str;
          default = "matthew";
          description = ''
            User who launches the VM. QEMU and virtiofsd run as this user, so
            it owns the tap device and is the only account that can put files
            into the drop box.
          '';
        };

        flake = lib.mkOption {
          type = lib.types.str;
          default = "/home/matthew/nixosconfig";
          description = "Flake the `claude-vm` launcher builds the VM from.";
        };
      };

      config = lib.mkIf cfg.enable {
        boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

        systemd.tmpfiles.rules = [
          "d ${vm.stateDir} 0750 ${cfg.owner} users -"
          "d ${vm.runDir}   0700 ${cfg.owner} users -"
          # The one-way drop box. ${cfg.owner} writes into it from here; the
          # guest gets it through virtiofsd's --readonly, which the guest
          # cannot override because virtiofsd is a host process.
          "d ${vm.shareDir} 0755 ${cfg.owner} users -"
        ];

        # NetworkManager would otherwise try to autoconfigure the tap.
        networking.networkmanager.unmanaged = [ "interface-name:${vm.interface}" ];

        systemd.services.claude-vm-net = {
          description = "Network isolation for the Claude browser VM";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-pre.target" ];
          before = [ "network.target" ];
          path = [ pkgs.iproute2 pkgs.nftables ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            # Pre-created and owned by ${cfg.owner} so QEMU can attach to it
            # without any privilege of its own.
            if ! ip link show ${vm.interface} > /dev/null 2>&1; then
              ip tuntap add dev ${vm.interface} mode tap user ${cfg.owner}
            fi

            # Rules first, so the interface is never up unfiltered.
            nft -f ${rules}

            ip addr replace ${vm.hostAddress}/${toString vm.prefixLength} dev ${vm.interface}
            ip link set ${vm.interface} up
          '';
          preStop = ''
            ip link set ${vm.interface} down || true
            nft delete table inet claude-vm || true
            ip link del ${vm.interface} || true
          '';
        };

        environment.systemPackages = [ launcher viewer ];
      };
    };
}

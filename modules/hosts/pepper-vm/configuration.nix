{ self, inputs, ... }: {
  # Pepper's sandbox: the personal assistant planned in ~/pepper
  # (.agent/plans/pepper-prd.md). A lightweight, headless guest whose only job
  # is reasoning over APIs -- corkboard's MCP server for tasks, plans and
  # memory, and (from Phase 3) read-only Google -- so it has no repos, no
  # vault, no GPU and no shares at all. Nothing of the host's filesystem is
  # reachable from inside it.
  #
  # The other half of the boundary is the network: egress is `allowlist`, so
  # the guest has no route off this machine and reaches only the hosts in
  # my.agentVms.instances.pepper-vm.allowedDomains, through the filtering proxy
  # on the gateway. That matters more here than anywhere else: Pepper reads
  # personal mail (untrusted text) while holding personal credentials, so the
  # allowlist is what addresses the exfiltration leg.
  #
  # Its code and settings live in this closure, not on a mount, so Pepper
  # cannot edit its own instructions: changing them is a host-side rebuild.
  # What it keeps between boots -- the Claude Code login, the corkboard MCP
  # credential, and the tokens under /var/lib/pepper -- is on its root disk.
  flake.modules.nixos.pepperVmConfiguration = { pkgs, lib, modulesPath, ... }:
    let
      vm = self.lib.agentVm.instances.pepper-vm;

      proxyUrl = "http://${vm.hostAddress}:${toString vm.proxyPort}";

      # The proxy, for every proxy-aware tool: Claude Code (and the MCP
      # connections it makes), curl, httpx. A tool that ignores these
      # reaches nothing, which is the right direction to fail. The guest has
      # no resolver either; the proxy resolves the names it allows.
      proxyEnv = {
        HTTP_PROXY = proxyUrl;
        HTTPS_PROXY = proxyUrl;
        http_proxy = proxyUrl;
        https_proxy = proxyUrl;
        NO_PROXY = "localhost,127.0.0.1";
        no_proxy = "localhost,127.0.0.1";
      };

      # Claude Code features whose hosts are absent from the allowlist, off,
      # so they never start a request the proxy will refuse. The same set
      # brain-vm ran with under its allowlist.
      claudeCodeEnv = {
        # claude.ai MCP connectors. A scope decision first: the personal
        # account brings Google Calendar *with write*, Drive, Docs and
        # Composio, and Pepper must not be able to write the calendar (an
        # accepted plan opens the dayplan gate, and only Matt accepts).
        ENABLE_CLAUDEAI_MCP_SERVERS = "false";
        # Artifact content reads (*.frame.claudeusercontent.com).
        CLAUDE_CODE_DISABLE_ARTIFACT = "1";
        # Datadog intake and the like. Also turns off feature-flag
        # evaluation, which is what gates Remote Control (see brain-vm's
        # claudeCodeEnv); Pepper has no phone channel in v1, so nothing is
        # lost yet.
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
        # Nix owns the binary.
        DISABLE_AUTOUPDATER = "1";
      };

      env = proxyEnv // claudeCodeEnv;

      # Policy Claude Code reads from /etc/claude-code and a user cannot
      # override. Declared here, so the guest cannot edit it either.
      managedSettings = {
        # Repeated from the environment so that an SSH session that loses
        # it (`env -i`, a stray profile) still gets no claude.ai connectors.
        env = claudeCodeEnv;

        # Pepper's memory (corkboard's Worker, ~/corkboard/.agent/plans/memory.md):
        # each session starts with its context and ends by sending its
        # transcript. Through the same Pepper token as the MCP server, so a
        # session with none has no memory hooks either.
        inherit (inputs.corkboard.lib.fleet.memoryHooks {
          inherit pkgs lib;
          tokenFile = "/var/lib/pepper/corkboard-token";
        }) hooks;
      };

      # The MCP servers Claude Code may use, all of them: with this file
      # present it takes exclusive control, so nothing in ~/.claude.json or a
      # project's .mcp.json can add another. corkboard as its own HTTP server,
      # not as the claude.ai connector, so the switch above does not catch it.
      # Its OAuth grant (`assistant`) is decided by the Worker.
      #
      # When corkboard's day plan window starts Pepper here (pepper-vm-ssh
      # claude, from nvim/lua/corkboard/plan/claude.lua), it first writes a
      # Pepper token into /var/lib/pepper/corkboard-token: the one grant that
      # sees the goals, revoked when that session ends. The helper hands it
      # to Claude Code as the Authorization header; without the file it
      # sends none, and Claude Code falls back to the OAuth login.
      corkboardHeaders = pkgs.writeShellApplication {
        name = "pepper-corkboard-headers";
        runtimeInputs = [ pkgs.jq ];
        text = ''
          token=/var/lib/pepper/corkboard-token
          if [ -s "$token" ]; then
            jq -cn --rawfile t "$token" '{ Authorization: ("Bearer " + ($t | rtrimstr("\n"))) }'
          else
            echo '{}'
          fi
        '';
      };

      managedMcp = {
        mcpServers.corkboard = {
          type = "http";
          url = "https://portal.corkboard.fyi/mcp";
          headersHelper = lib.getExe corkboardHeaders;
        };
      };

      # Phase 0's "done when", as one command. Run it in the guest.
      pepperCheck = pkgs.writeShellApplication {
        name = "pepper-check";
        runtimeInputs = [ pkgs.curl pkgs.coreutils ];
        text = ''
          ok=0
          pass() { echo "ok    $*"; }
          fail() { echo "FAIL  $*"; ok=1; }

          # Allowed hosts answer through the proxy (any HTTP status will do:
          # a 4xx from the far end still proves the path).
          for host in api.anthropic.com claude.ai platform.claude.com portal.corkboard.fyi oauth2.googleapis.com; do
            code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "https://$host/" || true)
            if [ "$code" != "000" ]; then pass "$host reachable ($code)"; else fail "$host unreachable"; fi
          done

          # Anything else is refused by the proxy...
          for host in example.com github.com mcp-proxy.anthropic.com; do
            code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "https://$host/" || true)
            if [ "$code" = "000" ]; then pass "$host refused"; else fail "$host reachable ($code)"; fi
          done

          # ...and there is no way around it: no resolver, no route.
          if getent hosts example.com >/dev/null 2>&1; then fail "the guest can resolve names"; else pass "no resolver"; fi
          if curl -s -o /dev/null -m 5 --noproxy '*' https://1.1.1.1/; then fail "direct route to 1.1.1.1"; else pass "no direct route"; fi

          # No shares.
          if [ -n "$(ls -A /mnt 2>/dev/null)" ]; then fail "/mnt has something in it"; else pass "no shares"; fi

          # Only corkboard as an MCP server; no claude.ai connectors.
          servers=$(claude mcp list 2>&1 || true)
          while IFS= read -r line; do echo "      $line"; done <<< "$servers"
          if echo "$servers" | grep -qi "claude.ai\|claude_ai"; then fail "claude.ai connectors listed"; else pass "no claude.ai connectors"; fi
          if echo "$servers" | grep -q "corkboard"; then pass "corkboard configured"; else fail "corkboard missing"; fi

          exit "$ok"
        '';
      };
    in
    {
      imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

      nixpkgs.hostPlatform = "x86_64-linux";
      # Claude Code is unfree.
      nixpkgs.config.allowUnfree = true;

      virtualisation = {
        # The guest's store is an image the launcher builds from this closure
        # on every start, read-only: Pepper runs what the host built, and
        # nothing else. Its root disk keeps the logins and tokens.
        useNixStoreImage = true;
        mountHostNixStore = false;
        writableStore = false;

        # No shares, not even the drop box: the PRD's "no shares, no outbox".
        # Credentials come in by typing or pasting on the console.
        sharedDirectories = lib.mkForce { };

        diskImage = vm.diskImage;
        # Home, ~/.claude and /var/lib/pepper; the store is a separate image.
        diskSize = 8192;
        memorySize = 1536;
        cores = 2;

        # No screen at all; the kernel and the boot log go to ttyS0, which
        # the headless service hands to the journal (`journalctl -u
        # pepper-vm` on the host).
        graphics = false;

        # ttyS0 to stdio for the journal; hvc0 to a unix socket on the host,
        # the way in for `pepper-vm-console`. See brain-vm for why a virtio
        # console rather than a second ISA serial port.
        qemu.options = [
          "-serial mon:stdio"
          "-device virtio-serial-pci"
        ] ++ lib.concatMap
          (i: [
            "-chardev socket,id=${vm.consoleChardevId i},path=${vm.consoleSocketFor i},server=on,wait=off"
            "-device virtconsole,chardev=${vm.consoleChardevId i}"
          ])
          vm.consoleIndices;

        # Replaces QEMU's user-mode networking, which would expose the host's
        # loopback to the guest as 10.0.2.2.
        qemu.networkingOptions = lib.mkForce [
          "-netdev tap,id=net0,ifname=${vm.interface},script=no,downscript=no"
          "-device virtio-net-pci,netdev=net0,mac=${vm.mac}"
        ];
      };

      # The console: a plain interactive bash on hvc0, attached by systemd.
      # Not an agetty, which never prompts on a socket-backed chardev (see
      # brain-vm's consoleServiceConfig), and with the generated agetty
      # masked so it cannot compete for the device.
      systemd.services = {
        pepper-console = {
          description = "Interactive console on ${vm.consoleDevice 1} for ${vm.name}-console";
          wantedBy = [ "multi-user.target" ];
          after = [ "dev-${vm.consoleDevice 1}.device" ];
          bindsTo = [ "dev-${vm.consoleDevice 1}.device" ];
          serviceConfig = {
            ExecStart = "${pkgs.bashInteractive}/bin/bash -il";
            User = "claude";
            Group = "users";
            WorkingDirectory = "/home/claude";
            StandardInput = "tty";
            StandardOutput = "tty";
            StandardError = "tty";
            Environment = [ "TERM=xterm-256color" ];
            TTYPath = "/dev/${vm.consoleDevice 1}";
            TTYReset = true;
            TTYVHangup = true;
            # The shell exits when the client detaches; keep one waiting.
            Restart = "always";
            RestartSec = "1s";
          };
          unitConfig.StartLimitIntervalSec = 0;
        };
        "serial-getty@${vm.consoleDevice 1}".enable = false;
      };

      networking = {
        hostName = "pepper-vm";
        usePredictableInterfaceNames = false;
        useDHCP = false;
        interfaces.eth0.ipv4.addresses = [{
          address = vm.guestAddress;
          prefixLength = vm.prefixLength;
        }];
        # No default route and no resolver: the gateway's proxy is on this
        # guest's own /24, and it is the only thing out there to reach.
        nameservers = lib.mkForce [ ];

        firewall.enable = true;
        # Everything from the gateway, which is the only address that can
        # reach this guest (the host's forward chain drops the rest): SSH,
        # and an `ssh -L` for an OAuth callback during a login.
        firewall.extraCommands = ''
          iptables -I nixos-fw 1 -s ${vm.hostAddress} -j nixos-fw-accept
        '';
        firewall.extraStopCommands = ''
          iptables -D nixos-fw -s ${vm.hostAddress} -j nixos-fw-accept || true
        '';
      };

      # `pepper-vm-ssh` on the host: a real pty, and as many sessions as
      # wanted. On the tap address only, keys only.
      services.openssh = {
        enable = true;
        listenAddresses = [{ addr = vm.guestAddress; port = 22; }];
        openFirewall = false;
        settings = {
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          PermitRootLogin = "no";
        };
      };

      # Both places: sessionVariables reach logins (the console, SSH), and
      # globalEnvironment reaches services (the Phase 6 heartbeat). Missing
      # either looks exactly like a blocked firewall.
      systemd.globalEnvironment = env;
      environment.sessionVariables = env;

      environment.etc."claude-code/managed-settings.json".text = builtins.toJSON managedSettings;
      environment.etc."claude-code/managed-mcp.json".text = builtins.toJSON managedMcp;

      # The credentials that are not Claude Code's own: the SDK token for the
      # heartbeat (Phase 6) and the Google token (Phase 3). Readable by
      # Pepper's user only.
      systemd.tmpfiles.rules = [ "d /var/lib/pepper 0700 claude users - -" ];

      users.mutableUsers = false;
      # `claude`, because `pepper-vm-ssh` and `-console` log in as it.
      users.users.claude = {
        isNormalUser = true;
        description = "Pepper";
        group = "users";
        # The VM is the boundary, not this password; SSH takes keys only.
        password = "claude";
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keyFiles = [ ./authorized-keys ];
      };

      environment.systemPackages = [ pkgs.curl pkgs.jq pepperCheck ];

      time.timeZone = "America/Phoenix";
      i18n.defaultLocale = "en_US.UTF-8";

      system.stateVersion = "26.11";
    };
}

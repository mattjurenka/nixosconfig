{ self, ... }: {
  # The second brain's sandbox. Headless -- no GPU, no compositor, no browser,
  # no SPICE -- because nothing here needs a screen: it runs Claude Code on a
  # schedule and writes its output to the vault share.
  #
  # Nothing of the host machine's filesystem is reachable from inside it except
  # ten virtiofs shares -- two writable (the vault and the outbox), eight
  # read-only. That is the boundary this VM now rests on.
  #
  # The guest's own disk is a third writable place, and since 2026-10-14 it is
  # the important one: the guest owns it completely. A GPT disk with its own
  # ESP, its own systemd-boot, and `/nix/store` as a plain directory on its own
  # ext4 root -- no store image, no host store mounted in, no overlay with the
  # host on the other side of it. The guest substitutes, builds, collects
  # garbage and rolls back like any other machine, and `nixos-rebuild switch
  # --flake /etc/nixos#brain-vm` in there is a real rebuild that survives a
  # power cycle. See `useNixStoreImage` below for what the old two-owner store
  # cost and why it went, and `brain-vm-install-disk` in
  # modules/features/agent-vm/host.nix for how the disk comes into existence.
  #
  # /var/lib/second-brain/work holds the git checkouts the brain works in and
  # pushes from, with the GitHub PATs wired into `git` and `gh` rather than
  # into a Python wrapper. The repo shares stay read-only because they are
  # Matt's working trees, not because git was something to withhold -- see the
  # `githubToken` comment below.
  #
  # The network half is gone as of 2026-10-11: egress is `open`, so the guest
  # reaches the public internet directly. Until then it had no route off the
  # machine at all and spoke only to a filtering proxy on an allowlist of
  # domains, with one routed exception for Steam's connection manager. The
  # proxy, that exception and the scoped resolver were removed together. What
  # survives is the host's forward chain dropping everything addressed into
  # private or link-local space, so the LAN and the router stay unreachable.
  #
  # See modules/features/agent-vm/host.nix for the half of the boundary the
  # guest cannot touch, and my.agentVms.instances.brain-vm on omni-laptop for
  # what opening egress gives up -- it is written out there rather than here,
  # because that is where the choice is expressed.
  flake.nixosModules.brainVmConfiguration = { config, pkgs, lib, modulesPath, ... }:
    let
      vm = self.lib.agentVm.instances.brain-vm;

      # virtiofs passes uids through unmapped, so the guest user has to *be*
      # the host user as far as the kernel is concerned, or every write to the
      # writable vault share fails with EACCES. matthew is uid 1002 and gid 100
      # (the `users` group, which already has gid 100 here) on the host; see
      # my.agentVms.owner.
      ownerUid = 1002;

      # Turn off the Claude Code features whose hosts are deliberately absent
      # from the proxy allowlist, so they never start a request that the proxy
      # will refuse. Without these, each one is a retry and a confusing error
      # rather than a feature that simply isn't present.
      claudeCodeEnv = {
        # claude.ai MCP connectors. A scope decision as much as a network one:
        # the account signing in here also has Dune, Vercel, YouTube and Docs
        # connectors, and a Stable-scoped brain must not inherit them.
        ENABLE_CLAUDEAI_MCP_SERVERS = "false";
        # Artifact content reads (*.frame.claudeusercontent.com).
        CLAUDE_CODE_DISABLE_ARTIFACT = "1";
        # CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC was here until 2026-10-11,
        # for the two Datadog intake hosts and the Gerrit change lookup. Removed
        # for two reasons.
        #
        # The rationale was network: those hosts were absent from the proxy
        # allowlist, so the switch stopped requests that would be refused
        # anyway. Egress is open now, so there is nothing to pre-empt.
        #
        # The reason it had to go rather than merely could: it also suppresses
        # **feature-flag evaluation**, and Remote Control is gated on it. The
        # availability chain is sign-in -> subscription -> `user:profile` scope
        # -> organization resolved -> `allow_remote_control` org policy ->
        # "Feature-flag evaluation enabled" -> "Remote Control enabled for this
        # account". With evaluation off, the gate cannot resolve, the feature
        # reads as not enabled, and the slash command is never registered -- so
        # `/remote-control` in the guest answered "unknown command" rather than
        # any error, which looks like a missing feature rather than a
        # suppressed flag fetch. Same switch also silently skipped the
        # version check, which is how it was spotted.
      };

      # Kept in its own file rather than a heredoc inside the self-test script:
      # Nix strips only the *common* indentation of a '' string, so an indented
      # heredoc body reaches Python still indented and dies with
      # IndentationError. At the let-block level this comes out flush-left.
      portCheckPy = pkgs.writeText "port-check.py" ''
        import socket

        for port in (${toString vm.proxyPort}, 22, 53, 631):
            s = socket.socket()
            s.settimeout(3)
            try:
                s.connect(("${vm.hostAddress}", port))
                print(f"${vm.hostAddress}:{port} : OPEN")
            except Exception as e:
                print(f"${vm.hostAddress}:{port} : blocked ({type(e).__name__})")
            finally:
                s.close()
      '';

      # What open egress still denies, which is the only part of the network
      # boundary left: private and link-local space. The host's forward chain
      # drops it, so a connect here must fail -- and unlike the egress
      # allowlist this is not something the guest can talk its way past, since
      # the rule lives in the host's own nftables table.
      #
      # Raw TCP rather than curl: there is no proxy in this path now, and curl
      # would have taken one if the environment still named it.
      privateCheckPy = pkgs.writeText "private-check.py" ''
        import socket

        # 1.1.1.1 is the control. If it fails, the guest has no egress at all
        # and the "must be blocked" lines below prove nothing -- the same trap
        # as the egress probe that returned 000 for every host and read as a
        # working allowlist.
        targets = [
            ("1.1.1.1", 443, "should connect (public control)"),
            ("192.168.0.1", 443, "must be blocked (LAN)"),
            ("192.168.1.1", 443, "must be blocked (LAN)"),
            ("10.0.0.1", 443, "must be blocked (private)"),
            ("172.16.0.1", 443, "must be blocked (private)"),
            ("169.254.169.254", 80, "must be blocked (link-local)"),
        ]

        for host, port, expectation in targets:
            s = socket.socket()
            s.settimeout(5)
            try:
                s.connect((host, port))
                result = "connected"
            except Exception as e:
                result = f"blocked ({type(e).__name__})"
            finally:
                s.close()
            print(f"{host}:{port} -> {result}   [{expectation}]")
      '';

      # `pkgs.python3`, deliberately, rather than a pinned version. This env
      # pinned python312 until 2026-10-13 and paid an hour of compiling for it.
      # Hydra builds the default interpreter's package set, so on this revision
      # onnxruntime, onnx, tokenizers, py-rust-stemmers, hf-xet and fastembed
      # are all in the binary cache for 3.14, and every one of them 404s at the
      # same version under 3.12. Measured both ways: pinned wanted four
      # derivations built, including the C++ onnxruntime *and* its bindings;
      # unpinned wants one trivial wrapper and a 65MB fetch. `pkgs.onnxruntime`
      # being cached never helped the pinned env, because that build is
      # parameterised by interpreter -- the 3.12-flavoured one is a different
      # derivation.
      #
      # That hour is also what starved the compositor and got this host
      # power-cycled by hand; see the nix-daemon weights in
      # ../../features/agent-vm/host.nix, which stay worth having for any other
      # heavy guest rebuild.
      #
      # So a version pin here needs a reason. Following the default costs a
      # rebuild whenever nixpkgs bumps its default interpreter, which is the
      # cheaper of the two bills. Nothing in the vault constrains the version:
      # every script under .claude/scripts imports stdlib plus the packages
      # below, with no PEP-594 casualties. Dropping the pin also retired an
      # `inline-snapshot` doCheck override, which existed only because that
      # package's tests failed under python312 on this revision -- the default
      # set ships it prebuilt.
      python = pkgs.python3.withPackages (ps: with ps; [
        claude-agent-sdk
        msal
        sqlite-vec
        httpx

        # The semantic half of Phase 3, deferred from 2026-10-09 to
        # 2026-10-13 on the belief that it cost an hour of compiling. It does
        # not: that hour was the python312 pin, not this package. On the
        # default interpreter fastembed and its onnxruntime, tokenizers and
        # py-rust-stemmers dependencies all come from the binary cache --
        # see the note above `python`.
        #
        # fastembed rather than sentence-transformers: the same all-MiniLM-L6-v2
        # weights either way, but the torch route priced out at 99 derivations
        # and 897MB against this one's 20 and 362MB.
        #
        # First use fetches ~80MB of ONNX weights from HuggingFace into
        # /var/lib/second-brain/models, so it needs the egress that opened on
        # 2026-10-11. Every embedding after that is local -- no vault text
        # leaves the guest, which is the whole reason not to call an
        # embeddings API.
        fastembed

        # guest/drive.py's --backend uinput path does `from evdev import
        # UInput, ecodes`. It has to be in *this* environment rather than a
        # bare python3Packages.evdev in systemPackages, because this env is
        # what owns python3 on the guest's PATH -- see ./valheim-client.nix.
        evdev
      ]);

      # The guest tty starts at the kernel default 80x24 and stays there, however
      # large the terminal on the far end is, because virtio-serial has no winsize
      # in its protocol and no SIGWINCH. That is why Claude Code looks cramped on
      # this console and fills the window when run on the host: nothing was wrong
      # with Claude Code or kitty, the size simply never crossed the link.
      #
      # `fit` asks the terminal over the byte stream, which is the one thing that
      # does cross. In its own file for the reason the port-check.py comment above
      # gives: this needs both ANSI escapes and shell parameter expansion, and
      # nesting that inside a Nix '' string is a quoting trap.
      fitConsole = pkgs.writeShellScriptBin "fit" (builtins.readFile ./fit.sh);

      # GitHub, as credentials rather than as an API.
      #
      # Until 2026-10-13 the guest reached GitHub only through
      # `.claude/scripts/integrations/github.py`: the PATs stayed in Python, and
      # the model got three write functions (comment on a PR, open a PR, comment
      # on an issue) behind a hardcoded repo allowlist. Anything else -- branch,
      # commit, push -- did not exist as a code path, so from the inside it read
      # as a missing capability, and the brain kept telling Matt it could not
      # push. That was true and it was the wrapper's fault.
      #
      # So the wrapper is gone and the credential is wired into the tools that
      # normally carry it: a git credential helper for `git push`, and a `gh`
      # that has already picked the right token. Scope now lives in the PAT --
      # which repos it selects, what it may do there -- rather than in the shape
      # of a Python module, which is where scope is enforceable anyway.
      #
      # All three read /var/lib/second-brain/github.env through the same
      # resolver, so there is one answer to "which token, and where from".
      githubToken = pkgs.writeShellScriptBin "brain-github-token"
        (builtins.readFile ./github-token.sh);

      gitCredentialGithub = pkgs.writeShellScriptBin "git-credential-github"
        (builtins.replaceStrings
          [ "@brainGithubToken@" ]
          [ "${githubToken}/bin/brain-github-token" ]
          (builtins.readFile ./git-credential-github.sh));

      # Shadows pkgs.gh deliberately: this is the only `gh` on the guest's PATH,
      # so no call has to remember to be made through a wrapper. The real binary
      # is reached by store path, which is also why there is no collision to
      # resolve in system-path -- pkgs.gh is not in it.
      ghWrapped = pkgs.writeShellScriptBin "gh"
        (builtins.replaceStrings
          [ "@brainGithubToken@" "@realGh@" ]
          [ "${githubToken}/bin/brain-github-token" "${pkgs.gh}/bin/gh" ]
          (builtins.readFile ./gh-wrapper.sh));

      # The credentials this guest's own disk carries, as one list, because two
      # kinds of session now need them: the console shells below, which get
      # them as systemd EnvironmentFile, and an SSH login, which gets them from
      # /etc/profile -- see environment.loginShellInit further down. Written
      # once because the failure mode of writing them twice is a credential
      # that works on a console and is absent over SSH, and from the inside
      # that reads as `gh` being broken rather than as an unset variable.
      #
      # Files on the guest disk rather than Nix because ~/nixosconfig is a
      # PUBLIC GitHub repo:
      #
      #   graph.env   Graph identifiers for the Stable mailbox. The tenant id is
      #               public information either way -- the OIDC discovery
      #               endpoint serves it from the domain name -- but the client
      #               id of a public client whose mail scopes are already
      #               consented is a device-code-phishing assist, so it stays
      #               out of anything published. Not a credential, not
      #               publishable either.
      #
      #   github.env  Two GitHub PATs, because a fine-grained PAT covers
      #               exactly one resource owner and the allowlist spans
      #               Stable-Finance and mattjurenka. These ARE credentials,
      #               unlike the Graph client id -- the other reason they are
      #               not in a public repo.
      #
      #   google.env  The Google OAuth client for gamemaster@verseworlds.fun,
      #               added 2026-10-10. Client id AND client secret: Google's
      #               installed-app flow issues a secret even though it does
      #               not treat it as one, and the refresh token next to it in
      #               google-token.json is the part that matters -- together
      #               they are full access to that account, including sending
      #               mail as it. The widest credential in this guest.
      credentialFiles = [
        "/var/lib/second-brain/graph.env"
        "/var/lib/second-brain/github.env"
        "/var/lib/second-brain/google.env"
      ];

      # What Zed's agent panel connects to, since 2026-10-17: the Agent Client
      # Protocol side of Claude Code, started by Zed's remote server *in this
      # guest* rather than on the laptop. Zed launches an external agent on the
      # far end of an SSH project, so a swarm of threads in the editor on the
      # host is a swarm of `claude` processes in here -- which is the whole
      # point, because here is where the credentials, the mounts and the
      # boundary are.
      #
      # A wrapper rather than pkgs.claude-agent-acp directly, for the reason
      # environment.loginShellInit exists further down and one more:
      #
      #   Credentials. The remote server is started by sshd as a *command*, so
      #   it gets `bash -c` and never reads /etc/profile -- the one place the
      #   guest loads github.env and the rest. An agent started that way would
      #   have no GitHub token, which from the inside reads as `gh` being
      #   broken rather than as an unset variable. Same files, same `set -a`
      #   dance, one layer earlier.
      #
      #   The scope switches. claudeCodeEnv reaches systemd units through
      #   globalEnvironment and login shells through sessionVariables, and an
      #   ACP agent is neither. Without them a Zed thread in here would be the
      #   only session on this guest with claude.ai MCP connectors enabled --
      #   that is a scope decision (see claudeCodeEnv above), so it should not
      #   depend on which door the agent came in through.
      #
      # No `cd`: Zed sets the agent's working directory per thread, to the
      # worktree that thread owns, and that is exactly what Claude Code should
      # load CLAUDE.md from. The checkouts under /var/lib/second-brain/work are
      # what to point Zed at -- the repo shares are read-only mounts of Matt's
      # own working trees, so a thread rooted in /opt/second-brain or
      # /mnt/stable-* cannot write, cannot branch and cannot make a worktree.
      #
      # claude-agent-acp carries its own claude-code by store path, and the
      # overlay in modules/features/claude-code.nix is what that resolves
      # through -- so a Zed thread and a console session run the same binary
      # and the same login in /home/claude/.claude.
      acpAgent = pkgs.writeShellApplication {
        name = "claude-acp";
        runtimeInputs = [ pkgs.claude-agent-acp ];
        text = ''
          for _cred in ${lib.concatStringsSep " " credentialFiles}; do
            if [ -r "$_cred" ]; then
              set -a
              # shellcheck disable=SC1090
              . "$_cred"
              set +a
            fi
          done
          unset _cred

          ${lib.concatStringsSep "\n"
            (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") claudeCodeEnv)}

          exec claude-agent-acp "$@"
        '';
      };

      # The other half of a Zed connection, and the half that is not obvious:
      # Zed wants a server process on the far end, and if it does not find one
      # it downloads its own from zed.dev. That binary is a dynamically linked
      # glibc build whose PT_INTERP is /lib64/ld-linux-x86-64.so.2 -- the same
      # thing steam-run exists for below -- so on a NixOS guest it cannot start
      # at all, and the failure arrives as a connection that hangs and then
      # fails rather than as a missing loader. `upload_binary_over_ssh` does
      # not help: it changes where the same unusable binary comes from.
      #
      # So the guest provides it, from the same nixpkgs that builds the Zed on
      # the host -- which is what makes the version match, and Zed checks the
      # version. The consequence is worth writing down: `nix flake update`
      # moves both sides, so after one the guest needs its own `nixos-rebuild
      # switch --flake /etc/nixos#brain-vm` before Zed can connect again. The
      # guest owns its disk and its system (see the header), so a host switch
      # does not do it.
      #
      # Two names because only one of them is the one Zed looks for. nixpkgs
      # installs the binary as `...-stable-1.20.1+stable`, following upstream's
      # own naming, and Zed resolves `~/.zed_server/zed-remote-server-<channel>-<version>`
      # -- whether its <version> carries the `+stable` depends on how the
      # release stamped itself. Linking both costs a symlink and removes a
      # guessing step; if neither is right, Zed's log on the host names the
      # path it wanted.
      zedRemoteServer = pkgs.zed-editor.remote_server;
      zedRemoteServerExe = pkgs.zed-editor.remoteServerExecutableName;

      # Everything a console shell needs, as a function of the console index.
      # Shared rather than repeated because the only thing that differs between
      # the N consoles is which hvcN they own -- and credential files repeated
      # three times is three places to forget one.
      #
      # agetty was tried twice and fails here in a way that is hard to see: the
      # unit starts, the process sits in S state with ExecMainStatus=0, and it
      # never emits a prompt or answers input, on both an ISA serial port and a
      # virtio console. It is built around serial-line semantics (carrier, baud
      # detection, login) that a socket-backed chardev does not provide.
      #
      # None of that machinery is wanted anyway: this is a single-user appliance
      # whose security boundary is the VM, not a password prompt -- the same
      # reasoning the browser VM's config already states. So skip straight to
      # the shell. StandardInput/Output = "tty" with TTYPath makes systemd open
      # the device and hand it over as the controlling terminal.
      consoleServiceConfig = i: {
        ExecStart = "${pkgs.bashInteractive}/bin/bash -i";
        User = "claude";
        Group = "users";
        # The credentials above, so an interactive session does not have to
        # export them. The leading `-` makes each one optional: before the file
        # exists the console still starts, and graph_auth.py says which
        # variables are missing rather than the shell failing to come up.
        EnvironmentFile = map (f: "-${f}") credentialFiles;
        # /opt/second-brain, not the vault: Claude Code loads CLAUDE.md and
        # .claude/ (hooks, from Phase 2) relative to the working directory, and
        # both live in the repo. The agent writes to /mnt/vault by absolute
        # path. Read-only cwd is fine -- session state goes to ~/.claude in the
        # guest's writable home.
        WorkingDirectory = "/opt/second-brain";
        StandardInput = "tty";
        StandardOutput = "tty";
        StandardError = "tty";
        # systemd hands a TTYPath-attached unit TERM=vt220 -- a real terminal
        # type and a poor one, so Claude Code falls back to a 16-colour reduced
        # renderer and it reads as the TUI being broken rather than
        # under-described. The client on the far end is kitty over socat, so say
        # so. The other half of what a terminal normally negotiates is the size,
        # which `fit` handles.
        Environment = [ "TERM=xterm-256color" ];
        TTYPath = "/dev/${vm.consoleDevice i}";
        TTYReset = true;
        TTYVHangup = true;
        # The shell exits whenever the socket client detaches -- and if reading
        # the port returns EOF while nothing is attached, it will exit
        # immediately and respawn in a tight loop. That is acceptable (it costs
        # nothing and means a shell is always waiting), but systemd's default
        # rate limiter would ban the unit after a few restarts and leave the
        # console permanently dead. Turning the limit off keeps it respawning
        # for as long as the VM is up.
        Restart = "always";
        RestartSec = "1s";
        StartLimitIntervalSec = 0;
      };
    in
    {
      imports = [
        "${modulesPath}/virtualisation/qemu-vm.nix"

        # The interactive consoles, as a nested module.
        #
        # A module rather than a plain attribute for a Nix reason rather than a
        # logical one: these units are *generated* from `vm.consoleIndices`,
        # which means assigning `systemd.services` wholesale -- and that cannot
        # sit in the same attrset literal as the `systemd.services.<name>`
        # definitions further down, because Nix reads defining an attribute and
        # defining its children as two definitions of the same attribute. An
        # entry in `imports` is a module in its own right, so the module system
        # merges the two sets properly. (`lib.mkMerge` would also merge them,
        # but it produces a *config* value, and `imports` is a module-level key
        # that cannot appear inside one.)
        {
          systemd.services =
            # One shell per console...
            (lib.listToAttrs (map
              (i: lib.nameValuePair "brain-console${if i == 1 then "" else toString i}" {
                description = "Interactive console ${toString i} on ${vm.consoleDevice i} for ${vm.name}-console";
                wantedBy = [ "multi-user.target" ];
                # Order against the device, not the target. `After =
                # multi-user.target` together with `WantedBy =
                # multi-user.target` is a cycle -- the target waits on this unit
                # while this unit waits on the target -- and systemd resolves it
                # by never starting the unit at all, silently: it does not
                # appear in the journal, and `systemctl show` reports
                # inactive/dead/NRestarts=0, which looks like a clean exit
                # rather than a job that never ran. This is the dependency shape
                # serial-getty@ uses.
                after = [ "dev-${vm.consoleDevice i}.device" ];
                bindsTo = [ "dev-${vm.consoleDevice i}.device" ];
                serviceConfig = consoleServiceConfig i;
              })
              vm.consoleIndices))
            # ...and the agetty the getty generator would otherwise put on each
            # device, masked. systemd-getty-generator instantiates
            # serial-getty@hvcN for every virtio console it finds, with no
            # configuration from us, and an unmasked one competes with the shell
            # above for the device. That is the failure the hvc0 note further
            # down describes, and it would have come back on hvc1 and hvc2 the
            # moment they existed.
            // (lib.listToAttrs (map
              (i: lib.nameValuePair "serial-getty@${vm.consoleDevice i}" { enable = false; })
              vm.consoleIndices));
        }
      ];

      nixpkgs.hostPlatform = "x86_64-linux";
      # Claude Code is unfree.
      nixpkgs.config.allowUnfree = true;

      virtualisation = {
        # The guest owns its filesystem outright, and this is the change that
        # makes it so (2026-10-14). It is the VMware-shaped arrangement rather
        # than the NixOS-test-shaped one that was here before, and it is worth
        # writing down what the old shape actually cost, because the symptoms
        # read as unrelated nix bugs and were all one thing.
        #
        # `/` was a bare ext4 image, but /nix/store was an overlay whose
        # lowerdir was an erofs image the *host* rebuilt from its own
        # evaluation of this file on every single launch, with the writable
        # half an upperdir on the guest's disk. Two layers, two owners, and one
        # SQLite database on the disk describing both of them.
        #
        # The database survives a reboot. The lowerdir does not -- it is thrown
        # away and regenerated -- so after any host-side rebuild the DB
        # described paths that were no longer on the filesystem. Nix trusts the
        # DB over the filesystem: addToStoreFromDump returns early when a path
        # is already valid, so an eval that needed to write a .drv again
        # skipped the write, and the next read of that file failed with "store
        # path '...' does not exist". That is `nix shell nixpkgs#awscli2` dying
        # on stdenv-linux-no-cc.drv on 2026-10-13, one boot after an earlier
        # eval had registered it. The stale rows did not self-heal; the cure
        # was to delete the DB and reload it from the regInfo on the kernel
        # command line, which is a thing a person had to know and do by hand.
        #
        # So: no store image, no host store, no overlay, no second owner.
        # `/nix/store` is a directory on the guest's own ext4 root, on its own
        # partition, on its own disk -- written once by make-disk-image when
        # the disk is installed and the guest's property from then on. It can
        # substitute, build, garbage-collect and roll back like any other
        # machine, and nothing the host does to its own store can invalidate a
        # path in here.
        #
        # The bill for that, stated plainly: builds move into the guest. The
        # host's store is no longer a free cache, so the first `nix develop` of
        # anything pays a download, and whatever has no binary cache compiles
        # on six vCPU instead of twelve. That is the better side of the trade
        # as of 2026-10-13 -- an onnxruntime compile in the host's nix-daemon
        # is what took this laptop down that day. In here it cannot.
        useNixStoreImage = false;
        mountHostNixStore = false;
        # Nothing left to overlay, so neither half of the overlay is wanted.
        # Explicit rather than defaulted, because `writableStore` defaults
        # *true*: left alone it would mount an overlay over a perfectly good
        # store directory and put the two-owner problem straight back.
        writableStore = false;

        # The other half of owning the filesystem: boot the disk.
        #
        # `directBoot` is upstream's default, and it is what made any nix work
        # the guest did pointless even when it succeeded. With it on, QEMU is
        # handed `-kernel`, `-initrd` and `init=` out of the closure the *host*
        # just evaluated, so whatever the guest had built and activated for
        # itself was thrown away at the next power cycle. Upstream says as
        # much in the option's own description: "this will not (re-)boot
        # correctly into a system that has switched to a different
        # configuration on disk."
        #
        # Off, the chain is the real one: QEMU starts OVMF, OVMF loads the
        # systemd-boot the guest installed on its own ESP, and the generation
        # the guest selected is the generation that comes up. `nixos-rebuild
        # switch` in here now means what it means anywhere else, and a bad one
        # is recoverable from the boot menu rather than by the host.
        #
        # `useEFIBoot` is what puts that firmware on the command line -- the
        # OVMF pflash pair, plus a writable variable store the launcher keeps
        # in the VM's state directory.
        #
        # `useBootLoader` is deliberately *not* set, despite sounding like the
        # option for exactly this. It would make the launcher's own derivation
        # depend on a full disk-image build, so every `systemctl start
        # brain-vm` would want to build a multi-gigabyte image before QEMU
        # could start, and a cold start after a config change would be minutes
        # of image build for an image nothing uses -- the disk already exists.
        # Instead the disk is installed once, deliberately, by
        # `brain-vm-install-disk`, and `system.build.installDisk` below is what
        # that script builds. See modules/features/agent-vm/host.nix.
        directBoot.enable = false;
        useEFIBoot = true;

        # Replaces the default set wholesale. Upstream also exports
        # $TMPDIR/xchg and $TMPDIR/shared read-write; dropping them leaves
        # these ten as the only ways in or out.
        sharedDirectories = lib.mkForce {
          # Read-only way in, for anything handed to the brain deliberately.
          # Read-only so that a file handed in cannot be altered or deleted by
          # the agent, and so nothing it writes can appear in the directory
          # Matt treats as "things I gave it".
          dropbox = {
            source = vm.shareDir;
            target = "/mnt/dropbox";
            writable = false;
          };

          # ...and the way back out, writable, because a read-only drop box
          # leaves the agent no way to hand a file back. Separate from the
          # vault on purpose: the vault is the memory Obsidian renders, not a
          # transit directory, and keeping the two apart means a file in
          # flight never has to be filed first.
          outbox = {
            source = vm.outboxDir;
            target = "/mnt/outbox";
            writable = true;
          };

          # The memory vault, and the only writable path the agent is meant to
          # *work* in -- the outbox above is transit, not storage. Between them
          # they are what replaces a write-confinement hook: an agent with full
          # Write tools still cannot touch anything else, because there is
          # nothing else to touch. virtiofsd runs on the host, so the guest
          # cannot remount the read-only shares read-write.
          vault = {
            source = "/home/matthew/second-brain/vault";
            target = "/mnt/vault";
            writable = true;
          };

          # The scripts, read-only, so the agent cannot rewrite its own
          # heartbeat. Same reasoning as protecting SOUL.md, applied to code.
          # Matt edits these on the host with his normal tools.
          code = {
            source = "/home/matthew/second-brain";
            target = "/opt/second-brain";
            writable = false;
          };

          # The two Stable repos, read-only. The brain needs to read the
          # codebase to be useful about product and protocol decisions, and
          # read-only at the mount level means it cannot modify them even by
          # accident -- the requirement was "everything outside the vault is
          # read-only to the brain", enforced here rather than by a hook.
          #
          # Only these two: baum-monorepo, baum-docs, verse,
          # nancy-tracker-onchain and youtube-mcp-server are out of scope and
          # stay unmounted, so they are not merely forbidden but absent.
          stable-monorepo = {
            source = "/home/matthew/stable-monorepo";
            target = "/mnt/stable-monorepo";
            writable = false;
          };

          stable-accounts = {
            source = "/home/matthew/stable-accounts";
            target = "/mnt/stable-accounts";
            writable = false;
          };

          # Added 2026-10-10. Matt corrected the scope: these four are Stable
          # work, not personal projects, and the earlier list had them
          # backwards. baum-monorepo in particular holds contract source --
          # the most security-critical code the old boundary excluded, and the
          # open "contracts-repo scope" question in the vault FINDINGS.
          #
          # verse is in Matt's own GitHub namespace and in scope regardless:
          # who owns a repo on github.com is not the same question as whose
          # work it is. nancy-tracker-onchain is mounted even though no PAT
          # Matt can issue reaches it over the API -- reading source and
          # calling the API are separate capabilities.
          #
          # Read-only, like the others. youtube-mcp-server stays unmounted: it
          # is genuinely personal and out of scope.
          baum-monorepo = {
            source = "/home/matthew/baum-monorepo";
            target = "/mnt/baum-monorepo";
            writable = false;
          };

          baum-docs = {
            source = "/home/matthew/baum-docs";
            target = "/mnt/baum-docs";
            writable = false;
          };

          verse = {
            source = "/home/matthew/verse";
            target = "/mnt/verse";
            writable = false;
          };

          nancy-tracker-onchain = {
            source = "/home/matthew/nancy-tracker-onchain";
            target = "/mnt/nancy-tracker-onchain";
            writable = false;
          };
        };

        diskImage = vm.diskImage;
        # The size `brain-vm-install-disk` gives the disk it creates, and since
        # 2026-10-14 that is the *only* thing this number does. qemu-vm.nix's
        # own create path is unreachable now: with `directBoot` off, an image
        # it created would be an empty ext4 filesystem with no bootloader and
        # nothing to boot, so the launcher refuses to start at all when the
        # disk is missing rather than letting it make one. The installer reads
        # this value out of the evaluated config, so this stays the single
        # place the number is written.
        #
        # 80 GiB, arrived at by doubling twice on 2026-10-13 and again on
        # 2026-10-14, for the same reason both times: the brain's git checkouts
        # live on this disk, because it clones the repos it works on into
        # /var/lib/second-brain/work rather than committing in the host's
        # working trees, which stay read-only mounts. The .git directories are
        # small (27 MB is the largest of the five) but the checkouts are not --
        # stable-monorepo, baum-monorepo and verse are 3.3, 3.9 and 2.8 GB on
        # the host once built. And as of this change the store is on here too,
        # which is the larger half: the old store image was 7.8 GB on its own,
        # and a store the guest can build in grows past that.
        #
        # **This number does not resize an image that already exists**, and
        # nothing in a rebuild will. Growing the live one means stopping it
        # first, because QEMU holds a write lock on the image and qemu-img
        # refuses rather than corrupting it:
        #
        #   sudo systemctl stop brain-vm
        #   nix shell nixpkgs#qemu-utils -c \
        #     qemu-img resize /var/lib/brain-vm/disk.qcow2 163840M
        #   sudo systemctl start brain-vm
        #
        # `nix shell` because qemu is not in systemPackages on the host -- it
        # reaches this machine only as a dependency of the VM's own runner
        # script, so `qemu-img` is in the store but not on PATH, and typing it
        # bare is a command-not-found.
        #
        # The guest then grows into it on the next boot by itself: `boot.
        # growPartition` below pushes the root partition out to the end of the
        # device and `autoResize` grows the ext4 inside it. Both halves are
        # needed now that there is a partition table -- before this change the
        # root image was a bare filesystem and `autoResize` alone was enough,
        # which is why the partition half is new.
        #
        # qcow2 is sparse, so this costs host disk only as the guest fills it.
        # The host has ~650 GB free, so the sparseness is a convenience rather
        # than load-bearing; the ceiling that matters day to day is still the
        # one on memory, not this.
        diskSize = 81920;

        # Grow the root filesystem to fill whatever the device turns out to be,
        # on every boot -- the filesystem half of the resize described above.
        #
        # `virtualisation.fileSystems` rather than the top-level `fileSystems`
        # because qemu-vm.nix defines the root entry there and applies
        # `mkVMOverride` to the whole set -- a plain `fileSystems."/"` here
        # would be outranked and silently dropped. Written this way it merges
        # into the module's own definition of `/`, which with
        # `useDefaultFilesystems` is /dev/disk/by-label/nixos: the label
        # make-disk-image puts on the root partition.
        #
        # It adds `x-systemd.growfs`, so systemd-growfs-root grows the ext4
        # filesystem via the kernel's resize ioctl -- no resize2fs, and nothing
        # to run by hand in the guest.
        fileSystems."/".autoResize = true;

        # The ESP, which upstream only mounts for itself when `useBootLoader`
        # is set -- and that option is off here for the reason given up by
        # `directBoot`. So it is mounted here instead, because the guest needs
        # it for the thing this whole change is for: `nixos-rebuild switch`
        # installs the bootloader entry for its new generation onto this
        # partition, and without /boot mounted that fails and the guest comes
        # back up on its old system wondering why.
        #
        # by-label/ESP rather than a partition number: make-disk-image hard-
        # codes that label on the EFI partition, and a label survives the
        # partition being grown or the disk being attached at a different index.
        fileSystems."/boot" = {
          device = "/dev/disk/by-label/ESP";
          fsType = "vfat";
          # vfat has no ownership, so the defaults mount it 0755 root-owned,
          # which is what bootctl wants. Nothing in the guest but the
          # bootloader installer has any business in here.
          options = [ "umask=0077" ];
        };

        # Raised 4096/2 -> 8192/4 -> 16384/6 over 2026-10-10 for the Valheim
        # protocol work on `verse`, cut back to 12288 on 2026-10-11, and to
        # 10240 the same day when ./gpu.nix landed. Valheim's own floor is 8 GB;
        # the 12288 above it was llvmpipe's, which held whole framebuffers and
        # every render target in guest RAM. Those live on the host's GPU now, so
        # the floor is the game's again and 2 GB over it leaves room for the
        # dedicated server beside the client.
        #
        # Giving the 2 GB back rather than keeping it is deliberate, and it is
        # the same ceiling argument as always, one step further on. A guest GPU
        # allocation under `drm_native_context` is host memory, mapped through
        # the device's host memory window and charged to QEMU as it is made --
        # so it lands inside the cgroup ceiling but *outside* `-m`. The ceiling
        # had ~800 MiB of slack above guest-plus-overhead, which is a texture
        # set, not a budget. Lowering this is what buys that slack back without
        # touching the one number on the host that stops a runaway guest.
        #
        # 16384 did not fit. The host has 22.5 GB and `swapDevices = [ ]`, and
        # a guest allocation is not a reservation -- QEMU faults pages in as
        # the guest touches them, so the cost only materialises once Valheim
        # actually loads. Measured: this VM's cgroup peaked at 18.79 GiB, and
        # the host had nothing left to reclaim but the text pages of its own
        # compositor. That is not an OOM kill, it is a livelock with the screen
        # still on -- twice on the evening of 2026-10-10.
        #
        # The real guard is on the host, not here, because this number cannot
        # enforce itself: see my.agentVms.instances.brain-vm.memoryMax on
        # omni-laptop, which is a cgroup ceiling 4 GiB above this figure now,
        # and the `memoryMax` option's own description for the mechanism.
        # Raising this without raising that one costs a guest OOM kill and a
        # ten-second restart, which is the failure landing where it belongs.
        #
        # Cores are no longer frame rate. That claim was true of software
        # rendering and is why this was once the highest-leverage knob in the
        # file; with the GPU doing the rendering these 6 vCPUs are Unity's
        # simulation and the dedicated server beside it. 6 of the host's 12
        # stays, and the host-side unit still carries CPUWeight=20 so they
        # yield to the compositor under contention.
        #
        # The "leaves room to start claude-vm alongside" property the original
        # note claimed stays retired: claude-vm asks for 8192, and even 10240 +
        # 8192 does not fit under what the host can spare. Both are deliberate,
        # interactive acts, so this remains a scheduling constraint rather than
        # a conflict to resolve in config -- the difference since 2026-10-11 is
        # that getting it wrong kills a VM instead of wedging the laptop.
        memorySize = 10240;
        cores = 6;

        # No *host-side* screen: no QEMU window, no SPICE, no VNC. Since
        # ./gpu.nix this is no longer the same as "no display device" -- the
        # guest has a virtio-gpu, and QEMU has an egl-headless backend behind
        # it because virtio-gpu-gl will not realize without an OpenGL context
        # to render into. egl-headless renders into GBM buffers on the host's
        # render node and opens nothing: no window, no port, nothing to attach
        # to. What this flag still buys is the thing it was set for -- QEMU
        # does not put a window on Matt's desktop, and the guest's console
        # stays on ttyS0/hvc0 rather than a framebuffer nobody can see.
        #
        # Screenshots still come back through the vault rather than a viewer;
        # the difference is that the frames they capture are now rendered on
        # the host's GPU instead of llvmpipe. See ./gpu.nix for what that
        # costs.
        graphics = false;

        # Four consoles, because one was not enough for a headless VM run as a
        # service and two were not enough once a session started living on one:
        #
        #   ttyS0 -> stdio, which systemd captures. This is the boot log;
        #            `journalctl -u brain-vm` reads it. Write-only: under
        #            systemd stdin is /dev/null, so nothing can be typed here.
        #   hvc0  -> a unix socket, which is the way *in*. `brain-vm-console`
        #            on the host attaches to it. Needed for the interactive
        #            `claude` login and for inspecting the guest.
        #   hvc1  -> and hvc2, the same thing again. The brain holds a long
        #   hvc2     `claude` session on one of these for hours, and a single
        #            console meant looking at anything else required detaching
        #            from it: QEMU's socket chardev serves one client at a
        #            time, and one shell on one tty cannot serve two
        #            attachments. `brain-vm-console` claims the lowest free
        #            one. Count lives in `consoles` in
        #            modules/features/agent-vm/plan.nix.
        #
        # A unix socket keeps this out of the network boundary entirely: it is
        # QEMU-level, guarded by file permissions, and the guest cannot use it
        # to reach anything.
        #
        # virtio-console rather than a second ISA serial (`-serial unix:...`):
        # with ISA serial the guest's agetty opens the port and then sits
        # there, never emitting its prompt and never answering input, because
        # the emulated UART gives it no carrier while no client is attached.
        # virtio-console has no carrier to model, so hvc0 behaves like a pipe
        # and the getty works whether or not anyone is listening.
        # One chardev/virtconsole pair per console, generated from the same
        # vm.consoleIndices the guest services and the host wrapper use.
        #
        # They have to be separate ports: QEMU's socket chardev serves one
        # client at a time. There is a `mux` option, but it multiplexes QEMU
        # *frontends* onto one backend (the monitor and a serial port sharing a
        # chardev), not clients onto one socket -- so it does nothing for this.
        # A second `UNIX-CONNECT` to a busy socket just sits in the kernel's
        # accept backlog looking like a hang.
        #
        # One virtio-serial-pci bus carries 31 ports, so three is nowhere near
        # needing a second controller.
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

      # The bootloader the guest installs for itself, on the ESP mounted
      # above. Nothing in the old arrangement needed one -- the host handed
      # QEMU a kernel and an init -- so this is new as of 2026-10-14 and it is
      # what makes a guest-side `nixos-rebuild switch` survive a power cycle.
      #
      # systemd-boot rather than GRUB because the firmware is OVMF and there
      # is no legacy path to support, and because it keeps a generation menu
      # the console can use: a rebuild that does not boot is recoverable from
      # in here, which matters for a VM whose whole point is that it is allowed
      # to change itself.
      boot.loader.systemd-boot.enable = true;

      # Not negotiable in this VM, for two separate reasons that happen to
      # agree. The firmware's variable store is a file the launcher keeps on
      # the host, so a variable written here is not a durable fact about any
      # machine; and `bootctl install --no-variables` writes the removable-
      # media fallback at EFI/BOOT/BOOTX64.EFI, which is the path OVMF finds
      # without being told anything. Setting this true would try to touch
      # efivarfs during a rebuild and fail.
      boot.loader.efi.canTouchEfiVariables = false;

      # Keep the menu bounded, and sized against the ESP rather than guessed.
      # The guest rebuilds itself now, so generations accumulate in here
      # instead of on the host, and a full ESP is a rebuild that fails at its
      # very last step -- after the closure is built and the profile is
      # switched, which is the worst place for it.
      #
      # This kernel is 14 MB and this initrd is 30 MB, so a generation costs
      # ~44 MB of ESP. Twenty of them is ~880 MB against the 2 GiB `bootSize`
      # set below: room for the count to be wrong by half without anything
      # breaking. make-disk-image's own default of 256 MiB would have held
      # five, which is the kind of ceiling you find by hitting it.
      boot.loader.systemd-boot.configurationLimit = 20;

      # The partition half of growing into a resized disk; `autoResize` above
      # is the filesystem half and cannot do anything until the partition it
      # lives in has moved. Runs before systemd-growfs-root, pushes the last
      # partition out to the end of the device, and exits 1 harmlessly when
      # there is nothing to grow -- which is every boot after the first.
      #
      # Needed only because there is a partition table now. The old root image
      # was a bare filesystem on a bare device with nothing in front of it.
      boot.growPartition = true;

      # Where the kernel logs, and this is not a nicety -- without it the boot
      # log of this VM disappears.
      #
      # qemu-vm.nix owns a `qemu.consoles` list and puts it on the kernel
      # command line itself, but only through the `-append` it builds for
      # `directBoot`. Turning direct boot off to let the guest boot its own
      # disk takes that `-append` away with it, and nothing replaces it: the
      # kernel command line now comes from the bootloader entry, which is
      # built from `boot.kernelParams`. With no `console=` in it the kernel
      # logs to tty0 -- the virtio-gpu framebuffer nobody is looking at -- so
      # `-serial mon:stdio` carries nothing and `journalctl -u brain-vm` on the
      # host shows a VM that started and then said nothing for the rest of its
      # life. The guest's own hvc consoles still work, because those are
      # systemd units with an explicit TTYPath, which is exactly why this is
      # easy to miss.
      #
      # Derived from `qemu.consoles` rather than written out, so the two cannot
      # disagree -- including the ordering, which is load-bearing: the kernel
      # points /dev/console at the *last* `console=` it is given, and upstream
      # reverses the list when `graphics` is false precisely so that the serial
      # port wins over tty0. Restating it here by hand would be one typo away
      # from a VM that logs to a framebuffer.
      boot.kernelParams =
        map (c: "console=${c}") config.virtualisation.qemu.consoles;

      # What `brain-vm-install-disk` builds: a complete NixOS installation --
      # GPT, an ESP with systemd-boot on it, an ext4 root holding the whole
      # store with its database already registered, and a system profile
      # pointing at this configuration's generation 1.
      #
      # This is its own invocation of make-disk-image rather than the one
      # qemu-vm.nix keeps privately behind `useBootLoader`, and the reason is
      # in that option's note above: upstream's copy is wired into the launcher
      # derivation, so having it at all would mean building a disk image on
      # every VM start. This one is built only when the installer asks for it,
      # which is once per machine lifetime.
      #
      # Everything the guest is -- every share in `sharedDirectories`, the
      # consoles, the GPU, Claude Code itself -- is already in `config` by the
      # time this is evaluated, so the image is this guest and not a generic
      # NixOS. The shares appear in its /etc/fstab as virtiofs mounts, which is
      # correct: they are the real mounts QEMU provides at runtime.
      system.build.installDisk = import "${modulesPath}/../lib/make-disk-image.nix" {
        inherit pkgs config lib;
        name = "brain-vm-disk";
        format = "qcow2";
        # GPT with an ESP, matching `useEFIBoot` on the QEMU side. Any of the
        # legacy layouts would boot nothing under OVMF.
        partitionTableType = "efi";
        # Labels the root partition `nixos`, which is what
        # `virtualisation.rootDevice` looks for by default.
        label = "nixos";
        # The step that makes the disk bootable at all: mounts the ESP, then
        # `nixos-enter`s the image and runs `switch-to-configuration boot`, so
        # the bootloader and the first generation are installed by the guest's
        # own activation scripts rather than approximated from outside.
        installBootLoader = true;
        # ...but without efivarfs in the build VM. It would be writing
        # variables into a throwaway firmware, and `canTouchEfiVariables =
        # false` above means nothing asks for them.
        touchEFIVars = false;
        # The ESP, eight times make-disk-image's default. 256 MiB holds five of
        # this guest's generations (44 MB each, see `configurationLimit`
        # above), and a guest that rebuilds itself will pass five generations
        # in an afternoon -- at which point `nixos-rebuild` fails on a full
        # vfat partition after having done all the work. 2 GiB out of 80 is
        # not a trade worth thinking about, and it is sparse until written.
        bootSize = "2048M";
        # Size the image to its contents and let the installer resize the copy
        # it makes to `virtualisation.diskSize`. Building an 80 GiB image here
        # would mean 80 GiB of store for a file that is thrown away after one
        # `qemu-img convert`.
        diskSize = "auto";
        # Slack on top of the closure, so the first boot has somewhere to write
        # before the resize takes effect.
        additionalSpace = "2048M";
        # No channels: this guest is a flake and `nix-channel` has no part in
        # how it updates itself.
        copyChannel = false;
        # 1 GiB is upstream's default and it is not enough to `nixos-enter` a
        # closure this size -- Claude Code, a Steam client and mesa are in it.
        memSize = 4096;
        OVMF = config.virtualisation.efi.OVMF;
      };

      # The flake the guest rebuilds itself from, seeded into a writable
      # /etc/nixos on first boot.
      #
      # This is the half of "the guest owns its filesystem" that is about nix
      # rather than about disks. A guest with a real store and a real
      # bootloader can still only rebuild a configuration it can see, and
      # nothing in the old arrangement gave it one: the flake lived on the host
      # and the guest's system arrived as a kernel on a command line. With this,
      # in the guest:
      #
      #   sudo nixos-rebuild switch --flake /etc/nixos#brain-vm
      #
      # and from then on it is a normal machine: edit the files, rebuild, roll
      # back from the boot menu if it was a bad idea.
      #
      # It comes in through the drop box rather than out of the Nix store, and
      # that is not a style choice -- the obvious version of this was
      # `cp -r ${self} /etc/nixos`, which works and is wrong. Interpolating
      # `self` puts the whole flake source in this guest's closure, so every
      # edit to any file in the repository -- including the host's own files,
      # including a comment -- changes the guest's system derivation and with
      # it the disk image. That is an 8 GB image build and a guest closure
      # rebuild triggered by editing a line of this host's niri config.
      # Measured: a host-only change moved the image's out path.
      #
      # Through the drop box, the closure depends on nothing but the guest, and
      # re-seeding is a file copy on the host rather than a rebuild. The share
      # is read-only, which is exactly right for a seed: the guest copies it
      # out once and owns the copy, and nothing it does to /etc/nixos can reach
      # back into what the host handed it.
      #
      # `brain-vm-install-disk` puts the tree there. If it is missing this
      # service says so and exits cleanly rather than failing the boot -- a
      # guest with no /etc/nixos is a guest that cannot rebuild itself, which
      # is a worse day than it sounds but not a reason to refuse to come up.
      #
      # What this discloses, because it is a real widening and should not be
      # discovered by surprise: the tree is the whole repository, so the agent
      # can read the host's own configuration -- including
      # modules/features/agent-vm/host.nix, which is the firewall and the
      # cgroup ceiling that contain it. It cannot *apply* any of that; a
      # guest-side rebuild builds a guest-side system, and the host's nftables
      # table and the virtiofsd flags are host processes it has no handle on.
      # But it can read the design of its own cage, and a boundary that only
      # held while its occupant could not read it was never holding.
      #
      # `git init` so the brain can commit its own changes and see what it has
      # altered since the seed; there is no remote and no pull, because the
      # seed came from a directory rather than a clone. Re-seeding means Matt
      # dropping a fresh tree in the drop box and removing /etc/nixos.
      systemd.services.seed-etc-nixos = {
        description = "Seed /etc/nixos with the flake this guest was built from";
        wantedBy = [ "multi-user.target" ];
        # The seed arrives over virtiofs, so the share has to be up. Ordered
        # after the root filesystem has been grown as well, since this is a
        # copy and the first boot is when the disk is still its install size.
        after = [ "local-fs.target" "mnt-dropbox.mount" ];
        wants = [ "mnt-dropbox.mount" ];
        path = [ pkgs.git pkgs.coreutils ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          seed=/mnt/dropbox/nixosconfig

          if [ -e /etc/nixos/flake.nix ]; then
            exit 0
          fi

          if [ ! -e "$seed/flake.nix" ]; then
            echo "No flake at $seed -- /etc/nixos left empty, so this guest"
            echo "cannot rebuild itself yet. Put a copy of the flake in the"
            echo "drop box on the host and restart this unit:"
            echo "    cp -r /home/matthew/nixosconfig /var/lib/brain-vm/share/"
            exit 0
          fi

          mkdir -p /etc/nixos
          # --no-preserve=mode because the share is read-only and the point of
          # this copy is that the guest can edit it.
          cp -rT --no-preserve=mode,ownership "$seed" /etc/nixos
          chown -R root:root /etc/nixos

          cd /etc/nixos
          if [ ! -d .git ]; then
            git -c init.defaultBranch=main init -q
            git add -A
            # Identity and gpgsign on the command rather than in a config:
            # whatever the brain sets up for itself afterwards is its own, and
            # this one commit should not be the thing that decides it.
            git -c user.email=brain@brain-vm -c user.name="brain-vm" \
              -c commit.gpgsign=false \
              commit -qm "seed: flake this disk was installed from"
          fi
        '';
      };

      networking = {
        hostName = "brain-vm";
        usePredictableInterfaceNames = false;
        useDHCP = false;
        interfaces.eth0.ipv4.addresses = [{
          address = vm.guestAddress;
          prefixLength = vm.prefixLength;
        }];
        # Open egress since 2026-10-11, so this is a real default route to
        # the public internet. The host's forward chain still drops everything
        # addressed into private or link-local space -- this laptop's LAN
        # address, the router, anything else on the same network -- which is
        # the only part of the old boundary that survives. See
        # my.agentVms.instances.brain-vm on the host for what was given up.
        defaultGateway = vm.hostAddress;

        # Public resolvers, matching claude-vm. The gateway is no longer one:
        # dnsmasq there was `mkIf (routed != {})` and existed only for the
        # Steam exception, which open egress required removing, and the
        # port-53 accept went with it. Pointing at vm.hostAddress now would
        # mean a guest with a route to the whole internet and no way to
        # resolve any of it -- which fails as "no network" and sends you
        # looking at the firewall.
        nameservers = [ "1.1.1.1" "9.9.9.9" ];

        firewall.enable = true;

        # Anything the guest listens on is reachable from the host, and from
        # nothing else. The point is a dev server: the brain starts something
        # on :3000 and Matt opens it in a real browser on the laptop, without
        # a port list here that has to be kept in step with whatever the agent
        # happened to pick today.
        #
        # By source address rather than by port, and ${vm.hostAddress} is the
        # gateway -- the only address of the host the guest can see. Nothing
        # else on the laptop's LAN can use this: the host's forward chain
        # drops everything addressed into the VM that is not a reply
        # (`oifname brvm0 counter drop`), so the host itself is the only
        # machine that can open a connection here in the first place. This
        # rule decides what happens once it arrives, not who may try.
        #
        # extraCommands rather than extraInputRules: this guest runs the
        # iptables backend, and the nftables-only option would silently not
        # apply. nixos-fw-accept rather than ACCEPT so it logs and counts the
        # way the rest of the chain does.
        firewall.extraCommands = ''
          iptables -I nixos-fw 1 -s ${vm.hostAddress} -j nixos-fw-accept
        '';
        firewall.extraStopCommands = ''
          iptables -D nixos-fw -s ${vm.hostAddress} -j nixos-fw-accept || true
        '';
      };

      # SSH, added 2026-10-16, because three consoles turned out to be a
      # ceiling rather than a comfort: each is one chardev serving one client,
      # the long-running `claude` session holds one for hours, and Matt hit the
      # end of the list. `brain-vm-ssh` on the host is the way in; the consoles
      # stay for the boots where there is no network yet.
      #
      # Nothing about the boundary moves for this. The guest already has a
      # static address on the tap, the host's input chain already accepts the
      # replies to connections the host opens, and the firewall rule above
      # already accepts everything from ${vm.hostAddress} -- the same path the
      # dev-server case uses. The host's forward chain drops every non-reply
      # addressed into this guest, so the laptop remains the only machine that
      # can open a connection here at all. This adds a daemon, not a hole.
      #
      # What it buys beyond a fourth shell is a real pty. virtio-serial carries
      # no window size and no SIGWINCH, which is the entire reason `fit` exists
      # and why Claude Code renders into an 80x24 box on a console; over SSH the
      # size crosses the link at login and resizes follow it. Scrollback belongs
      # to the terminal again, `ssh -L` can bring a dev server to the host
      # browser without the guest's address in the URL bar, and the number of
      # sessions is whatever is wanted.
      services.openssh = {
        enable = true;

        # Only on the tap address, so the daemon listens exactly where the
        # firewall already says it is reachable. Nothing on 0.0.0.0 to be found
        # by whatever else this guest is given a route to later.
        listenAddresses = [{ addr = vm.guestAddress; port = 22; }];

        # The rule above accepts everything from the gateway, which is the only
        # address that can reach this guest in the first place, so port 22 is
        # already open to the one client there is. `openFirewall` would add an
        # accept for port 22 from *anywhere* -- strictly wider, and it buys
        # nothing.
        openFirewall = false;

        settings = {
          # `password = "claude"` above is explicitly not a boundary (the VM
          # is), and it should not quietly become one on a network socket.
          # Keys only, from ./authorized-keys.
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          PermitRootLogin = "no";
        };

        # Host keys are the default pair, generated on first start and kept in
        # /etc/ssh on the guest's own ext4 root -- so they survive a reboot and
        # change only when the disk is reinstalled. `brain-vm-ssh` deliberately
        # does not pin them; the wrapper says why.
      };

      # No proxy any more: tinyproxy was `mkIf (allowlisted != {})` and this
      # was the only allowlisted instance, so the variables that used to live
      # here would now name a dead port. Removed rather than pointed somewhere
      # else -- an unset HTTPS_PROXY means every tool takes the direct route,
      # which since 2026-10-11 is the route that works.
      #
      # claudeCodeEnv stays. Those three switches turn off Claude Code features
      # whose hosts were deliberately absent from the allowlist, and with the
      # allowlist gone they are no longer *forced* -- but each was a scope
      # decision as much as a network one (claude.ai MCP connectors would pull
      # in this account's Dune, Vercel, YouTube and Docs connectors, which a
      # Stable-scoped brain should not inherit), so they are left off until
      # someone decides otherwise rather than re-enabled by accident.
      systemd.globalEnvironment = claudeCodeEnv;

      environment.sessionVariables = claudeCodeEnv;

      # The same credentials, for a session systemd did not start.
      #
      # `consoleServiceConfig` hands the console shells `credentialFiles` as
      # EnvironmentFile, and an SSH login never passes through systemd's
      # environment at all -- so without this the brain is fully equipped on a
      # console and has no GitHub token one `ssh` away, which presents as `git
      # push` asking for a password and `gh` claiming it is not logged in.
      #
      # /etc/profile is the right place because it covers both halves of what
      # arrives over SSH: the interactive login shell `brain-vm-ssh` drops into,
      # and the `bash -lc` it wraps a one-shot command in. It does *not* affect
      # the consoles, which run `bash -i` under systemd and are already covered.
      #
      # `set -a` exports whatever the file assigns. These files are plain
      # KEY=value, which is the intersection of what systemd's parser and
      # bash's `.` read the same way -- a value with a `#` or a bare quote in it
      # would not be, and would need single-quoting to stay readable by both.
      #
      # The `cd` is the other half of what a console gets for free:
      # WorkingDirectory is /opt/second-brain there, because Claude Code loads
      # CLAUDE.md and .claude/ relative to the working directory and both live
      # in the repo. An SSH session would otherwise land in /home/claude and
      # start a *generic* agent in a guest built to run a specific one.
      environment.loginShellInit = ''
        for _cred in ${lib.concatStringsSep " " credentialFiles}; do
          if [ -r "$_cred" ]; then
            set -a
            . "$_cred"
            set +a
          fi
        done
        unset _cred

        cd /opt/second-brain 2>/dev/null || true
      '';

      users.mutableUsers = false;
      users.users.claude = {
        isNormalUser = true;
        description = "Second brain";
        uid = ownerUid;
        group = "users";
        # The VM is the security boundary, not this password.
        password = "claude";
        extraGroups = [ "wheel" ];
        # Who may log in over SSH, with the reasoning in the file itself. A
        # keyFile rather than `keys` so the base64 is not in the Nix and the
        # list can carry comments.
        openssh.authorizedKeys.keyFiles = [ ./authorized-keys ];
      };

      services.getty.autologinUser = "claude";

      # The console on hvc0 is a plain interactive bash, attached to the tty by
      # systemd -- not an agetty.
      #
      # agetty was tried twice and fails here in a way that is hard to see: the
      # unit starts, the process sits in S state with ExecMainStatus=0, and it
      # never emits a prompt or answers input, on both an ISA serial port and a
      # virtio console. It is built around serial-line semantics (carrier,
      # baud detection, login) that a socket-backed chardev does not provide.
      #
      # None of that machinery is wanted anyway: this is a single-user
      # appliance whose security boundary is the VM, not a password prompt --
      # the same reasoning the browser VM's config already states. So skip
      # straight to the shell. StandardInput/Output = "tty" with TTYPath makes
      # systemd open the device and hand it over as the controlling terminal.
      # Left for reference: NixOS only wires a getty to the consoles it knows
      # about, and hvc0 is not one of them. Superseded by brain-console above.
      #
      # This must pull in the *template instance*, not define a concrete
      # `serial-getty@ttyS1` service. Defining the concrete unit replaces the
      # `serial-getty@` template rather than instantiating it, producing a unit
      # with no ExecStart and no TTYPath: systemd reports it as started and
      # nothing runs. (The tty still echoes typed characters, because the
      # kernel's default line discipline does that with no reader attached --
      # which makes the broken version look convincingly like a live shell.)
      #
      # `overrideStrategy = "asDropin"` is what makes that work: the definition
      # becomes a drop-in on the instance instead of a replacement unit, so the
      # template's ExecStart -- and the NixOS drop-in that adds
      # `--autologin claude` -- both still apply, and the socket lands on a
      # shell rather than a login prompt.
      # Mask the getty systemd would otherwise put here itself.
      #
      # systemd-getty-generator auto-instantiates serial-getty@hvcN for virtio
      # consoles it finds, with no configuration from us -- so removing our
      # own definition did not remove the agetty. It kept starting and
      # competing with brain-console for /dev/hvc0, which is why the console
      # stayed dead even after switching away from agetty. `enable = false`
      # masks the instance so brain-console owns the device outright.

      # Phase 6c. Promotes yesterday's daily log into MEMORY.md once a day, so the
      # curated layer stays current without Matt maintaining it by hand and the logs
      # stop being the only place durable facts live.
      #
      # A service plus a timer rather than something the agent does during a session:
      # reflection has to happen when nobody is mid-task, it rewrites a file that every
      # session loads, and it must run exactly once per day rather than once per
      # session. The guest's timezone is America/Phoenix (set below), so `OnCalendar`
      # is local time with no DST to reason about.
      # The host's taskbar shows one square per Claude Code session, and a
      # session registry only ever covers its own machine -- Remote Control is
      # what lets a session here be driven from elsewhere, but nothing outside
      # this guest can enumerate what is running in it. So this guest reads
      # itself and hands the answer out through the outbox, which the host
      # merges into its own reading.
      #
      # A dotfile because the outbox is the directory Matt treats as "things
      # the brain handed me", and this is plumbing rather than a handoff. It is
      # the only thing written here that he did not ask for, and it carries
      # session names, states and working directories -- nothing the host did
      # not already know how to display.
      # Drops Nix database rows whose store path is no longer on the disk, once
      # per boot, before anything can trip over one.
      #
      # The divergence the `writableStoreUseTmpfs = false` note above describes
      # is fixed going forward, but it was never self-healing: /nix/var/nix/db
      # lives on the persistent root image, so every row an earlier
      # tmpfs-store boot wrote is still there, still claiming a path that went
      # away with the tmpfs. Nix trusts the row over the filesystem and skips
      # the write, so the next eval that needs that path again dies reading it
      # -- version-check-hook.drv on 2026-10-14, which is `nix build
      # nixpkgs#hello` failing in the guest, which is no builds at all: no
      # tsc, no `nix develop`, nothing the brain writes can be compiled where
      # it was written.
      #
      # And the same shape recurs without any tmpfs, which is the reason this
      # is a unit rather than a one-off repair: the read-only half of the store
      # is an erofs image rebuilt from the closure at every launch, so a
      # generation change retires paths the persistent database still lists.
      #
      # `nix-store --verify` is the prune for both. It stats every valid path
      # and invalidates the ones that are gone, referrers first so a chain
      # clears in one pass; without `--check-contents` it hashes nothing, so
      # the cost is one stat per path.
      systemd.services.nix-db-prune = {
        description = "Prune Nix database rows for store paths that are gone";
        # The same unit shape as upstream's register-nix-paths, which is what
        # this has to run behind: it writes the SQLite database directly, so it
        # needs no default dependencies and no daemon, and it has to finish
        # before anything opens the store.
        unitConfig.DefaultDependencies = false;
        wantedBy = [ "sysinit.target" ];
        after = [ "register-nix-paths.service" ];
        before = [
          "sysinit.target"
          "shutdown.target"
          "nix-daemon.socket"
          "nix-daemon.service"
        ];
        conflicts = [ "shutdown.target" ];
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # Never fatal. --verify exits non-zero when it finds a path it could
        # not invalidate because something still valid refers to it, and this
        # unit runs before sysinit.target -- a failure there is a boot that
        # stops in emergency mode, where a locked root account means no getty
        # and the console a person attaches to is silent. That is the failure
        # the store-image note above already describes; a leftover row is
        # worth a line in the journal, not that.
        script = ''
          ${lib.getExe' config.nix.package.out "nix-store"} --verify || \
            echo "nix-db-prune: --verify reported errors, see above" >&2
        '';
      };

      systemd.services.claude-ready-publish = {
        description = "Publish this guest's Claude Code sessions to the host";
        wantedBy = [ "multi-user.target" ];
        after = [ "mnt-outbox.mount" ];
        requires = [ "mnt-outbox.mount" ];
        # The watcher shells out to `claude` for the registry rather than
        # parsing it, so the guest's own Claude Code is what answers.
        path = [ pkgs.claude-code ];
        serviceConfig = {
          # The console sessions run as claude, so its home holds the registry.
          User = "claude";
          Group = "users";
          ExecStart = lib.getExe (self.lib.mkClaudeReadyWatch { inherit pkgs; });
          Environment = [
            "CLAUDE_READY_ORIGIN=${vm.name}"
            "CLAUDE_READY_OUT=/mnt/outbox/.claude-sessions.json"
          ];
          Restart = "always";
          RestartSec = 5;
        };
      };

      systemd.services.memory-reflect = {
        description = "Promote yesterday's daily log into MEMORY.md";
        after = [ "network.target" "mnt-vault.mount" ];
        requires = [ "mnt-vault.mount" ];
        serviceConfig = {
          Type = "oneshot";
          User = "claude";
          Group = "users";
          # /opt/second-brain, same as brain-console: the Agent SDK session this
          # spawns loads CLAUDE.md and .claude/ relative to the working directory.
          # Writes go to /mnt/vault by absolute path, so a read-only cwd is correct.
          WorkingDirectory = "/opt/second-brain";
          # It talks to api.anthropic.com over the ordinary route since egress
          # went open on 2026-10-11; systemd.globalEnvironment
          # above is what reaches a unit's environment at all -- which since
          # egress went open on 2026-10-11 no longer includes any proxy
          # setting, because there is no longer a proxy.
          #
          # Nothing else is needed. memory_reflect.py runs its session with
          # allowed_tools=[], so unlike the heartbeat it reaches no integration and
          # needs none of the credential EnvironmentFiles.
          ExecStart = "${python}/bin/python /opt/second-brain/.claude/scripts/memory_reflect.py";
          # One Opus call and a file write. If it hangs, it hangs holding nothing, but
          # a stuck unit would block the next day's run via the timer's own serialisation.
          TimeoutStartSec = "15m";
        };
      };

      systemd.timers.memory-reflect = {
        description = "Daily memory reflection at 08:00 Phoenix";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "08:00";
          # The VM is not always up at 08:00 -- it is a laptop. Persistent means the
          # run happens on the next boot after a missed window instead of being
          # skipped, which matters because a skipped day is a day whose log never
          # gets promoted and which `pending_logs` then has to catch up on in a batch.
          Persistent = true;
          # Spread the start so it never lands exactly on top of whatever else a
          # cold boot is doing.
          RandomizedDelaySec = "5m";
        };
      };

      # Checks the isolation boundary from the inside on every boot and leaves
      # the report in the vault, where the host can read it. Two reasons this
      # is a permanent unit rather than a one-off script: the boundary is the
      # whole point of this VM and is worth re-verifying whenever the config
      # changes, and it means verification never depends on the console being
      # usable -- the vault share is a far more reliable channel than a tty.
      systemd.services.boundary-selftest = {
        description = "Verify the isolation boundary from inside the guest";
        wantedBy = [ "multi-user.target" ];
        # brain-console.service so the console section of the report describes
        # the console's real state rather than catching it before it starts.
        after = [ "network.target" "mnt-vault.mount" "mnt-outbox.mount" "brain-console.service" ];
        requires = [ "mnt-vault.mount" "mnt-outbox.mount" ];
        serviceConfig = {
          Type = "oneshot";
          User = "claude";
          Group = "users";
        };
        path = [ pkgs.curl pkgs.util-linux pkgs.coreutils pkgs.gnugrep pkgs.procps pkgs.systemd pkgs.iproute2 pkgs.claude-code python ghWrapped githubToken pkgs.git ];
        script = ''
          # This is a report, not a gate: NixOS wraps unit scripts with
          # `set -e`, which would abort the whole run on the first check that
          # exits non-zero -- and "this command failed" is a result worth
          # recording, not a reason to stop.
          set +e

          out=/mnt/vault/.boundary-selftest.txt
          exec > "$out" 2>&1
          echo "# brain-vm boundary self-test -- $(date '+%Y-%m-%d %H:%M:%S %Z %z')"
          echo

          echo "## identity (uid must be 1002 to match the host owner)"
          id
          echo

          echo "## mounts"
          # findmnt takes a single path, not a list.
          for m in /mnt/vault /mnt/outbox /mnt/dropbox /opt/second-brain \
                   /mnt/stable-monorepo /mnt/stable-accounts /mnt/baum-monorepo \
                   /mnt/baum-docs /mnt/verse /mnt/nancy-tracker-onchain; do
            findmnt -no TARGET,FSTYPE,OPTIONS "$m" || echo "$m : NOT MOUNTED"
          done
          echo

          echo "## filesystem boundary"
          if touch /mnt/vault/.probe 2>/dev/null; then
            echo "vault     rw : ok (writable, as designed)"; rm -f /mnt/vault/.probe
          else
            echo "vault     rw : FAILED -- uid mismatch?"
          fi
          if touch /mnt/outbox/.probe 2>/dev/null; then
            echo "outbox    rw : ok (writable, as designed)"; rm -f /mnt/outbox/.probe
          else
            echo "outbox    rw : FAILED -- uid mismatch, or source dir missing?"
          fi
          touch /mnt/dropbox/.probe 2>/dev/null \
            && echo "dropbox   ro : UNEXPECTEDLY WRITABLE" \
            || echo "dropbox   ro : refused (correct)"
          touch /opt/second-brain/.probe 2>/dev/null \
            && echo "code      ro : UNEXPECTEDLY WRITABLE" \
            || echo "code      ro : refused (correct)"
          for r in stable-monorepo stable-accounts baum-monorepo baum-docs \
                   verse nancy-tracker-onchain; do
            touch "/mnt/$r/.probe" 2>/dev/null \
              && echo "$r ro : UNEXPECTEDLY WRITABLE" \
              || echo "$r ro : refused (correct)"
          done
          # Out of scope: must not be mounted at all.
          for absent in /mnt/youtube-mcp-server /mnt/usdx-contracts; do
            [ -e "$absent" ] && echo "$absent : PRESENT (unexpected)" \
                             || echo "$absent : absent (correct)"
          done
          echo

          echo "## git and GitHub credentials"
          # The credential, not the API wrapper that used to stand in front of
          # it. Reported here because "I don't have access to GitHub" was being
          # said from inside sessions whose uid could read the tokens the whole
          # time, and this unit inherits no EnvironmentFile at all -- so a
          # "resolves" line here proves the file path works on its own, which is
          # the half that was in doubt.
          #
          # Counts and yes/no only. No token reaches this file, which Matt reads
          # in Obsidian.
          echo "GH_TOKEN_* in this unit's env : $(env | grep -c '^GH_TOKEN_')  (expected 0 -- no EnvironmentFile here)"
          for owner in Stable-Finance mattjurenka; do
            if brain-github-token "$owner" >/dev/null 2>&1; then
              echo "$owner : resolves from /var/lib/second-brain/github.env"
            else
              echo "$owner : NO TOKEN -- git push and gh will fail for its repos"
            fi
          done
          echo "unattended sessions are refused the file fallback:"
          CLAUDE_INVOKED_BY=selftest brain-github-token Stable-Finance >/dev/null 2>&1 \
            && echo "  FAILED -- CLAUDE_INVOKED_BY=selftest still got a token" \
            || echo "  ok (refused, as designed)"
          echo "credential helper configured : $(git config --get credential.https://github.com.helper || echo MISSING)"
          echo "gh on PATH                   : $(command -v gh)"
          echo "work dir                     : $(ls -ld /var/lib/second-brain/work 2>&1)"
          echo "work dir contents            : $(ls /var/lib/second-brain/work 2>/dev/null | tr '\n' ' ')"
          echo "free on /                    : $(df -h / | tail -1)"
          echo

          echo "## host secrets must be absent"
          for p in /home/matthew "$HOME/.ssh" "$HOME/.aws" "$HOME/.foundry"; do
            [ -e "$p" ] && echo "$p : PRESENT (unexpected)" || echo "$p : absent (correct)"
          done
          echo

          echo "## guest network"
          ip -br addr show
          echo "-- routes --"
          ip route
          echo "-- neighbours --"
          ip neigh
          echo "-- raw TCP to the host (nothing should answer: the proxy and the"
          echo "   gateway resolver both went away with the allowlist) --"
          # python, not bash's /dev/tcp: this unit runs with an explicit `path`
          # that has no bash, so `timeout bash -c ...` failed with "No such
          # file or directory" -- which printed as "blocked" and silently
          # turned every port check into a false pass.
          python ${portCheckPy}
          echo "-- what does curl actually do now? No proxy in the path. --"
          curl -v -o /dev/null --max-time 15 https://api.github.com 2>&1 | grep -vE "^\{|^\}" | head -15
          echo

          echo "## egress -- open since 2026-10-11, so all of these should answer"
          for u in https://graph.microsoft.com/v1.0/me \
                   https://login.microsoftonline.com \
                   https://api.github.com \
                   https://api.anthropic.com \
                   https://cache.nixos.org/nix-cache-info \
                   https://registry.npmjs.org \
                   https://codeload.github.com \
                   https://example.com \
                   https://pastebin.com ; do
            code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$u" 2>&1 | tail -1)
            printf '%-45s -> %s\n' "$u" "$code"
          done
          echo "(an HTTP status means it was reached. 000 or an error now means a real"
          echo " failure -- DNS, routing or the host being down -- not a refused proxy."
          echo " pastebin.com answering is not a fault: it is what open egress means,"
          echo " and it is recorded here so the report never implies otherwise.)"
          echo
          echo "(the last three are the reason this was opened: a nix flake over a pnpm"
          echo " workspace cannot build without cache.nixos.org, codeload.github.com"
          echo " and registry.npmjs.org)"
          echo

          # The port scan that used to be repeated here in bash is gone rather
          # than fixed: this unit's `path` has no bash, so `timeout bash -c
          # exec 3<>/dev/tcp/...` failed with ENOENT on every port and printed
          # "blocked" for all of them -- a check that could only pass. The
          # python one above is the real one, and with 53 now open on the
          # gateway the two would have contradicted each other in the report.

          echo "## dns is general-purpose now, against 1.1.1.1 and 9.9.9.9"
          for n in api.steampowered.com cache.nixos.org registry.npmjs.org \
                   example.com pastebin.com graph.microsoft.com; do
            if getent hosts "$n" >/dev/null 2>&1; then
              printf '%-32s -> resolves\n' "$n"
            else
              printf '%-32s -> no answer\n' "$n"
            fi
          done
          echo "(all of these should resolve. Until 2026-10-11 resolution was itself an"
          echo " allowlist, answered by dnsmasq on the gateway; that resolver is gone and"
          echo " a name failing here now means DNS is broken, not that it was refused.)"
          echo

          echo "## what open egress still denies: private and link-local space"
          python ${privateCheckPy}
          echo "(the control must connect and every private target must be blocked. A"
          echo " blocked control makes the rest of this section meaningless -- it would"
          echo " read as a tight boundary and mean the guest has no egress at all.)"
          echo

          echo "## toolchain"
          python -c "import msal, sqlite_vec, httpx, claude_agent_sdk; print('python imports : ok')" 2>&1 | tail -1
          python -c "import sqlite3; sqlite3.connect(':memory:').execute('CREATE VIRTUAL TABLE t USING fts5(x)'); print('sqlite fts5    : ok')" 2>&1 | tail -1
          printf 'claude-code    : '; { claude --version 2>&1 || echo unavailable; } | tail -1
          printf 'gh             : '; { gh --version 2>&1 || echo unavailable; } | head -1
          echo

          echo "## console -- is anything actually serving hvc0?"
          ls -l /dev/hvc0 2>&1 || echo "/dev/hvc0 : MISSING"
          echo "-- processes holding a tty --"
          ps -eo pid,tty,stat,comm 2>/dev/null | grep -E "agetty|bash|login" | grep -v grep \
            || echo "(nothing found)"
          echo "-- brain-console (should be the only thing on hvc0) --"
          systemctl is-active brain-console.service 2>&1
          systemctl show brain-console.service -p SubState -p ExecMainStatus -p NRestarts --no-pager 2>&1
          # Every console, not just hvc0: the getty generator instantiates one
          # per virtio console, so adding consoles re-opened this on hvc1/hvc2.
          # Both halves are worth asserting -- the shell up, the agetty masked --
          # because the failure mode is them competing for the device, which
          # looks like a console that echoes typed characters but never answers.
          for i in ${lib.concatMapStringsSep " " toString vm.consoleIndices}; do
            dev=hvc$((i - 1))
            unit="brain-console$([ "$i" = 1 ] && echo "" || echo "$i")"
            echo "-- console $i: $unit on $dev --"
            echo "shell          : $(systemctl is-active "$unit.service" 2>&1)"
            echo "getty masked   : $(systemctl is-enabled "serial-getty@$dev.service" 2>&1)"
            echo "socket in guest: $([ -c "/dev/$dev" ] && echo "/dev/$dev present" || echo "/dev/$dev MISSING")"
          done
          echo

          echo "## timezone (must be America/Phoenix / MST / -0700, no DST)"
          date '+%Z %z'
          echo
          echo "SELFTEST_COMPLETE"
        '';
      };

      # Derived state that must not live on the vault share: the Graph token
      # cache (0600, and the host reads the vault in Obsidian), the RAG index (a
      # hot SQLite file with WAL, which virtiofs is the wrong place for) and now
      # the git checkouts. Token cache and index rebuild or re-authenticate if
      # lost; `work/` holds real work, so see below.
      systemd.tmpfiles.rules = [
        "d /var/lib/second-brain 0700 claude users -"

        # Where the brain clones the repos it works on, as of 2026-10-13.
        #
        # The repo mounts stay read-only, and that is not a restriction being
        # worked around -- they are Matt's own working trees, with his dirty
        # files, his index and his HEAD, and an agent committing in them would be
        # changing the state he is working in. A clone here is the normal answer:
        # its own checkout, its own branches, pushed to the same remote.
        #
        # On the guest disk rather than a share, which is the trade accepted on
        # 2026-10-13: nothing here is visible from the host, so work that matters
        # has to be pushed rather than left in a branch. `diskSize` was doubled
        # in the same change to make room, and doubled again on 2026-10-14.
        "d /var/lib/second-brain/work 0700 claude users -"

        # Where Zed looks for its remote server, as of 2026-10-17. See
        # zedRemoteServer above for why the guest supplies this binary instead
        # of letting Zed fetch one, and why there are two names for it.
        #
        # The directory belongs to claude rather than root so that a Zed which
        # decides it wants to write here can, instead of failing in a way that
        # looks like an SSH problem. `L+` replaces whatever is at the path, so
        # a binary a previous Zed downloaded is cleared out on the next boot
        # rather than shadowing the working one forever.
        "d /home/claude/.zed_server 0755 claude users -"
        "L+ /home/claude/.zed_server/${zedRemoteServerExe} - - - - ${zedRemoteServer}/bin/${zedRemoteServerExe}"
        "L+ /home/claude/.zed_server/${lib.removeSuffix "+stable" zedRemoteServerExe} - - - - ${zedRemoteServer}/bin/${zedRemoteServerExe}"
      ];

      # claude-code itself comes from self.nixosModules.claude-code, imported
      # alongside this module in ./default.nix.
      #
      # Claude Code's credentials are per-machine, and this is a different
      # machine: run `claude` once here to log in. With no browser in the guest
      # it prints a URL -- open that on the host and paste the code back on
      # this console. api.anthropic.com and the login hosts must be in
      # my.agentVms.instances.brain-vm.allowedDomains, or this fails with an
      # auth error rather than an obvious network one.

      # Same reasoning as fit.sh for living in its own file: shell parameter
      # expansion and a Nix '' string both spell substitution with ${...}, and
      # escaping every one of them by hand is how this got written wrong twice.
      programs.bash.interactiveShellInit = builtins.readFile ./console-rc.sh;

      # git, configured so that cloning, committing and pushing need no setup
      # inside the guest -- /opt/second-brain is a read-only mount, so a
      # ~/.gitconfig written by the agent would be the one thing it could not
      # keep anyway. Everything here is machine-wide and declarative.
      environment.etc."gitconfig".text = ''
        [user]
            # A distinct name on the author line so a commit says which of the
            # two wrote it, and Matt's own commit email so GitHub still
            # attributes it to his account. Change the name if the authorship
            # should read as his.
            name = Second Brain
            email = matt.jurenka@comcast.net

        [credential "https://github.com"]
            # The helper takes the owner from the URL and resolves that owner's
            # PAT; `useHttpPath` is what makes the owner visible to it at all.
            # Without it git sends only `host=github.com`, and one token would
            # be used for both owners -- which fails on whichever one it is not
            # scoped to, in the shape of a 403 that reads like a revoked token.
            helper = ${gitCredentialGithub}/bin/git-credential-github
            useHttpPath = true

        [url "https://github.com/"]
            # Every repo mount's `origin` is an SSH remote, because that is how
            # Matt cloned it on the host -- and this guest has no SSH key and is
            # not getting one, since the PAT is the credential and ssh would be
            # a second one with wider scope. Rewriting to HTTPS means a clone of
            # a mount keeps working without anyone editing a remote by hand.
            insteadOf = git@github.com:
            insteadOf = ssh://git@github.com/

        [push]
            # `git push` on a fresh branch creates it upstream instead of
            # printing the --set-upstream hint. The brain works on throwaway
            # branches, so that hint was the common case.
            default = current
            autoSetupRemote = true

        [init]
            defaultBranch = main

        [pull]
            # Never a merge commit nobody asked for; a conflicting pull stops
            # and says so instead.
            ff = only
      '';

      environment.systemPackages = [
        python
        fitConsole

        # Claude Code with a Zed agent panel on the other end of it; see
        # acpAgent above. On PATH rather than referenced by store path from the
        # host's Zed settings, because a store path is only valid on the machine
        # that evaluated it: the editor names `claude-acp` and nothing else, and
        # both machines answer to it -- this one with the wrapper above, the host
        # with a one-line script of its own (home.packages in
        # modules/features/zed.nix). Renaming it here breaks every remote thread
        # until that file agrees again.
        acpAgent

        # The wrapper, not pkgs.gh: see ghWrapped above. The resolver is on PATH
        # too, so `brain-github-token <owner>` is how a console answers "do I
        # actually have a credential for this org" without printing one.
        ghWrapped
        githubToken

        pkgs.jq
        pkgs.sqlite
        pkgs.git
        pkgs.vim
        pkgs.ripgrep

        # Valheim protocol work on `verse`, in scope since 2026-10-10. Requested by
        # the brain itself through /mnt/outbox; the rationale is its, the
        # verification ours. Nothing here touches egress, mounts or credentials.
        #
        # mono covers all three tools verse-rewrite/tests/ProtocolTests/run.sh
        # checks for by name: `mcs`, `mono` and `ikdasm` are all in mono's own bin,
        # so no separate ikdasm package -- which matters, because there is no
        # `ikdasm` attribute in nixpkgs at all and that would have been a blocker.
        # The game assemblies target Unity's mscorlib and will not load under
        # .NET 8, so dotnet does not substitute for this.
        pkgs.mono

        # Builds the BepInEx plugins; every src/*/*.csproj targets net462. Pinned
        # rather than the floating `dotnet-sdk`: a build toolchain that moves under
        # you is what this config exists to prevent.
        pkgs.dotnetCorePackages.sdk_8_0

        # tools/server/valheim_server.x86_64 is a prebuilt ELF whose PT_INTERP is
        # /lib64/ld-linux-x86-64.so.2. That path exists in the guest but resolves
        # to NixOS's stub loader, which exists only to print a refusal -- so a
        # binary that runs on a Debian host cannot start here at all. steam-run is
        # the FHS userenv every Unity game on NixOS goes through.
        #
        # It is an FHS environment inside the sandbox, which is worth saying out
        # loud: it widens what a process in the guest can find on a filesystem it
        # was not built for. It does NOT widen the boundary that matters here --
        # egress is still default-deny plus the CONNECT allowlist, every mount
        # except the vault and outbox is still read-only, and no credential is
        # added. Unfree, which costs nothing extra: allowUnfree is already true
        # above for Claude Code.
        pkgs.steam-run
      ];

      # No man pages, info pages or doc outputs in an appliance nobody reads
      # documentation on. It keeps the guest's closure smaller and is the right
      # call here regardless of anything else.
      #
      # It used to carry a second justification: NixOS pulls each package's
      # "doc" output into system-path, and python3.12-doc failed to build on
      # this revision with a Sphinx crash. That was a third symptom of the
      # interpreter pin dropped on 2026-10-13 -- python3.14-doc is cached --
      # so the breakage is gone and only the original reason is left.
      documentation.enable = false;

      time.timeZone = "America/Phoenix";
      i18n.defaultLocale = "en_US.UTF-8";

      nix.settings.experimental-features = [ "nix-command" "flakes" ];

      # The guest's own user, trusted. An untrusted user can still build, so
      # this is not what was breaking builds -- but it is what lets the brain
      # repair its own store (`nix-store --repair-path` is refused outright to
      # an untrusted user), point an eval at a different substituter, and read
      # the diagnostics `nix store info` only shows a trusted caller. Every one
      # of those is otherwise something it has to ask Matt to run on the host,
      # which is the loop this is here to close.
      #
      # It grants no authority inside the guest that the account did not
      # already have: `claude` is in `wheel` on a single-user appliance whose
      # password is declared in plaintext in this file, because the security
      # boundary is the VM and not anything within it.
      # Appended to the default `[ "root" ]` rather than replacing it, which is
      # why root is not repeated here.
      nix.settings.trusted-users = [ "claude" ];

      system.stateVersion = "26.11";
    };
}

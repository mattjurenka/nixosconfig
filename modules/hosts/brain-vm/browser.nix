{ ... }: {
  # A driveable Chromium in the brain VM, with a wallet extension loaded into
  # it. Added 2026-10-17, because the guest could reach a dapp over HTTP since
  # egress opened and still could not *use* one: signing is a browser
  # extension's job, and there was no browser in here at all.
  #
  # The display is not the new part. ./gpu.nix already put a real X server on
  # :0, on the virtio-gpu, with openbox, xdotool, scrot and ffmpeg's x11grab
  # beside it for the Valheim client -- so "headless" in the request means "no
  # human at a screen", which this guest has always been, and not "no X". That
  # distinction decides the default below:
  #
  #   headful on :0        what `wallet-chrome` and the smoke test use. A full
  #                        Chromium, extensions and their MV3 service workers
  #                        behave exactly as they do on a desktop, and the
  #                        existing capture tooling can see the window.
  #   --headless=new       available, and what to reach for if the X server is
  #                        in the way. Still the full browser, so extensions
  #                        load; Playwright spells it `channel="chromium"`.
  #   headless shell       Playwright's `headless=True` default since 1.49.
  #                        **Does not support extensions.** Kept installed
  #                        (see browsers below) because plain scraping is
  #                        cheaper on it, but any wallet work that lands here
  #                        fails with the extension silently absent, which is
  #                        the one failure mode in this file worth memorising.
  #
  # Three doors, in increasing order of how much they do for you:
  #
  #   wallet-chrome      a Chromium with the extension already loaded, on :0.
  #                      For looking at something by hand.
  #   wallet-smoke       launches it from Python, resolves the extension ID,
  #                      screenshots the wallet's own page. The thing to run
  #                      first when something stops working.
  #   wallet-dapp-init   writes a node project that already has dAppwright
  #                      pinned and one passing test, for the half this file
  #                      cannot do from Python: driving MetaMask's onboarding
  #                      -- importing a seed, setting a password, approving
  #                      prompts -- which is a pile of version-specific CSS
  #                      selectors that someone else maintains.
  #
  # What this accepts, in the shape ./gpu.nix and ./valheim-client.nix use.
  #
  # A browser is a new *execution* surface rather than a new network one: the
  # guest has had open egress since 2026-10-11, so nothing here reaches
  # further than curl already did. What is new is that remote JavaScript now
  # runs in-process, with a profile directory that persists between runs.
  #
  # And a wallet extension holds a key. This guest already stores two GitHub
  # PATs and a Graph token under /var/lib/second-brain, so the standing advice
  # is not "be careful" but "keep the seed worthless": a throwaway mnemonic on
  # a testnet, funded with faucet money, and never a mainnet account. The
  # profile is deliberately put in $HOME rather than next to those credentials.
  flake.modules.nixos.brainVmBrowser = { pkgs, lib, ... }:
    let
      # MetaMask, as the vendor publishes it. Pinned by version rather than
      # tracking latest: an extension that changes under an automation script
      # is the same class of problem as a toolchain that does, which is what
      # the dotnet pin next door is about.
      #
      # 13.50.0 specifically, which is `MetaMaskWallet.recommendedVersion` in
      # the dAppwright this guest scaffolds against. dAppwright's onboarding
      # is a sequence of CSS selectors clicked in a real UI, so "the version
      # its selectors were written against" is the only version worth running;
      # it warns on the console about any other. 13.52.0 was the pin for a few
      # hours on 2026-10-17 and was moved back for exactly this reason.
      #
      # fetchurl of the zip rather than fetchzip of the tree, so the hash in
      # this file is the *vendor's own* checksum and can be re-checked without
      # Nix in the picture. Verified 2026-10-17 against the SHA256SUMS asset of
      # the same release:
      #
      #   curl -sL https://github.com/MetaMask/metamask-extension/releases/download/v13.50.0/SHA256SUMS \
      #     | grep metamask-chrome-13.50.0.zip
      #   b759caca275dec1a10edfebb9d1de1d26589a92104d8b0523ec442930e20e47c
      #
      #   nix hash convert --hash-algo sha256 --to sri b759ca...
      #
      # The stable build, not -flask: flask is the developer channel and ships
      # unreleased RPC surface, which makes it the wrong thing to write a test
      # against unless the test is about that surface.
      metamaskZip = pkgs.fetchurl {
        url = "https://github.com/MetaMask/metamask-extension/releases/download/v13.50.0/metamask-chrome-13.50.0.zip";
        hash = "sha256-t1nKyidd7BoQ7f67nR3h0mWJqSEE2LBSPsRCkw4g5Hw=";
      };

      # dAppwright's extension public key, lifted from its dist bundle
      # (src/downloader/constants.ts, EXTENSION_PUB_KEY). It is published, not
      # secret -- it is a *public* key, and the matching private key is only
      # needed to sign a CRX, which nothing here does.
      #
      # Why it matters enough to copy: Chromium derives an unpacked
      # extension's ID from the absolute path it was loaded from *unless* the
      # manifest carries a `key`, and MetaMask's release manifest does not.
      # dAppwright solves that by rewriting manifest.json after it downloads,
      # which pins the ID to gadekpdjmpjjnnemgnhkbjgnjpdaakgh and lets its own
      # code hardcode that. Injecting the same key here means the Python path
      # and the dAppwright path see one extension with one ID, instead of two
      # copies that disagree -- and it is what lets the store copy be handed
      # to dAppwright at all, since its rewrite needs a writable directory and
      # a store path is not one.
      dappwrightPubKey =
        "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnpiOcYGaEp02v5On5luCk/4g9j+ujgWeGlpZVibaSz6kUlyiZvcVNIIUXR568uv5NrEi5+j9+HbzshLALhCn9S43E7Ha6Xkdxs3kOEPBu8FRNwFh2S7ivVr6ixnl2FCGwfkP1S1r7k665eC1/xYdJKGCc8UByfSw24Rtl5odUqZX1SaE6CsQEMymCFcWhpE3fV+LZ6RWWJ63Zm1ac5KmKzXdj7wZzN3onI0Csc8riBZ0AujkThJmCR8tZt2PkVUDX9exa0XkJb79pe0Ken5Bt2jylJhmQB7R3N1pVNhNQt17Sytnwz6zG2YsB2XNd/1VYJe52cPNJc7zvhQJpHjh5QIDAQAB";

      # The ID the key above produces. Hardcoded in dAppwright, and asserted by
      # ./wallet-smoke.py rather than trusted: if a dAppwright bump changes its
      # key, the smoke test says so instead of a dapp test failing weirdly a
      # week later.
      extensionId = "gadekpdjmpjjnnemgnhkbjgnjpdaakgh";

      # Unpacked, because --load-extension wants a directory. A store path is
      # read-only and that is fine -- Chromium only writes to the profile.
      metamask = pkgs.runCommand "metamask-chrome-13.50.0" {
        nativeBuildInputs = [ pkgs.unzip pkgs.jq ];
      } ''
        mkdir -p $out
        unzip -q ${metamaskZip} -d $out
        jq --arg key '${dappwrightPubKey}' '.key = $key' \
          $out/manifest.json > $out/manifest.json.new
        mv $out/manifest.json.new $out/manifest.json
      '';

      # Chromium's own browsers, for Playwright. Firefox and WebKit dropped
      # from the bundle: 444 MiB of downloads becomes 271 MiB, and neither
      # engine takes a Chromium extension, so they could only ever be a
      # slower way to fail at the thing this file exists for.
      #
      # chromium-headless-shell is deliberately *kept* despite the warning at
      # the top. Without it `headless=True` -- Playwright's default -- does
      # not fail with "extensions do not work here", it fails with "executable
      # doesn't exist", on a path nobody wrote. One confusing error is worth
      # 100 MiB on an 80 GiB disk.
      browsers = pkgs.playwright-driver.browsers.override {
        withFirefox = false;
        withWebkit = false;
      };

      # The interactive door: a Chromium with the extension already in it, on
      # whatever DISPLAY is set -- :0 here, from ./gpu.nix.
      #
      # WALLET_EXTENSION is the point of the indirection. The default is the
      # MetaMask above, but any unpacked extension directory works, which is
      # how a build of Matt's own extension gets driven without changing this
      # file: point it at the unpacked dist/ and nothing else moves.
      #
      # --disable-extensions-except alongside --load-extension because
      # --load-extension alone is ignored when any other extension policy is
      # in play; the pair is the documented incantation and is what every
      # wallet test harness emits.
      walletChrome = pkgs.writeShellScriptBin "wallet-chrome" ''
        set -eu
        ext="''${WALLET_EXTENSION:-${metamask}}"
        profile="''${WALLET_PROFILE:-$HOME/.local/share/wallet-chrome}"
        mkdir -p "$profile"
        exec ${lib.getExe pkgs.chromium} \
          --user-data-dir="$profile" \
          --disable-extensions-except="$ext" \
          --load-extension="$ext" \
          --no-first-run \
          --no-default-browser-check \
          "$@"
      '';

      # dAppwright's cache, pre-filled. Added 2026-10-17 alongside the
      # scaffold below.
      #
      # dAppwright does not take an extension path: it downloads MetaMask from
      # the GitHub releases API at bootstrap, extracts it to
      # $TMPDIR/dappwright/<wallet>/<version with dots as underscores>, injects
      # the key above, and writes an empty `.success` beside it. Every later
      # run sees that file and skips the download.
      #
      # So the cheapest way to make the guest's dapp tests deterministic is to
      # write that directory ourselves from the store copy. What it buys:
      # the same MetaMask the Python path uses, no GitHub API call on the hot
      # path (that call is unauthenticated by default and rate-limited by IP,
      # which is a flaky test suite waiting to happen -- dAppwright reads
      # GITHUB_TOKEN if one is set, but not needing the call at all is
      # better), and a test run that works with egress down.
      #
      # Copied rather than symlinked, and chmod'd writable, because
      # dAppwright rewrites manifest.json in place. It will find the key
      # already there and write it again, which is a no-op.
      # dAppwright puts more than the cache under this root -- a `session`
      # directory next to it, at least -- so the whole tree has to belong to
      # the brain, not just the leaf the seed unit writes. Found the hard way:
      # the first guest-side run failed with EACCES on mkdir
      # /tmp/dappwright/session, because a root-owned root is invisible as a
      # problem until something tries to write a sibling.
      dappwrightRoot = "/tmp/dappwright";
      dappwrightCacheDir = "${dappwrightRoot}/metamask/13_50_0";

      # The scaffold. dAppwright belongs in a project's package.json rather
      # than in a system closure -- it is a test-suite dependency, and the
      # dapps the brain works on bring their own node_modules -- so this
      # installs the *starting point* instead of the library: a directory that
      # already has the versions pinned correctly and one passing test.
      #
      # The @playwright/test pin is the part worth not getting wrong. npm's
      # playwright validates the browser revision it finds under
      # PLAYWRIGHT_BROWSERS_PATH against its own expectation, so a version
      # that is not 1.63.0 -- the nixpkgs playwright-driver on this revision --
      # fails with "Executable doesn't exist" pointing at a chromium-#### that
      # was never built. Bumping nixpkgs means bumping the scaffold.
      #
      # playwright-core is pinned *again*, with an npm `overrides` entry,
      # because dAppwright declares it as a peer at `>1.0`. Without the
      # override npm hoists the newest one -- 1.64.1 on 2026-10-17 -- and
      # dAppwright's own `require` picks that up rather than the 1.63.0 under
      # @playwright/test. Measured: the test failed with "Executable doesn't
      # exist at ./chromium-1248", while the bundle holds chromium-1243. The
      # two playwrights were different versions in one node_modules, which
      # the error says nothing about.
      #
      # package-lock.json ships with the scaffold so `npm install` resolves
      # the tree that was actually tested rather than whatever is newest.
      walletDappInit = pkgs.writeShellScriptBin "wallet-dapp-init" ''
        set -eu
        dir="''${1:-$PWD/wallet-e2e}"
        if [ -e "$dir" ]; then
          echo "$dir already exists -- refusing to write over it." >&2
          exit 1
        fi
        mkdir -p "$dir"
        cp -rT --no-preserve=mode,ownership ${./dappwright-scaffold} "$dir"
        chmod -R u+w "$dir"
        echo "Scaffold written to $dir"
        echo
        echo "  cd $dir && npm install && npm test"
        echo
        echo "npm install needs the network; the wallet itself does not --"
        echo "MetaMask is already in dAppwright's cache at"
        echo "${dappwrightCacheDir}."
      '';

      # Prove the stack before blaming a dapp for anything -- the same habit
      # as glmark2 in ./gpu.nix and glxinfo in ./valheim-client.nix. It
      # launches the browser, resolves the extension ID the only reliable way,
      # opens the wallet's own home page and screenshots it. A green run means
      # browser, extension, service worker and screen all work; a dapp failing
      # after that is the dapp.
      #
      # Its own file for the reason the port-check heredoc in
      # ./configuration.nix gives: Nix strips only the common indentation of a
      # '' string, so an indented Python body arrives still indented and dies
      # with IndentationError.
      walletSmoke = pkgs.writeShellScriptBin "wallet-smoke" ''
        set -eu
        export WALLET_EXTENSION="''${WALLET_EXTENSION:-${metamask}}"
        # `python3` from PATH, not a withPackages env built here. The guest has
        # exactly one Python -- the one in ./configuration.nix -- and
        # `playwright` was added to it rather than to this wrapper, for the
        # reason CORRECTION 2 in ./valheim-client.nix writes out: a second env
        # is a second set of importable modules, and the brain's own scripts
        # under .claude/scripts can only ever see the first one.
        exec python3 ${./wallet-smoke.py} "$@"
      '';
    in
    {
      environment.systemPackages = [
        # The browser the wrapper drives. Separate from Playwright's own
        # Chromium on purpose: this one has a stable path on PATH for a human
        # on the console or an agent typing a command, and that one is the
        # build Playwright pins itself against. Asking either to be the other
        # trades ~200 MiB for a version-skew bug at the worst moment.
        pkgs.chromium
        walletChrome
        walletSmoke
        walletDappInit

        # Node, for the dAppwright half. A dapp test suite is a node project
        # whatever else is true, and `npm install` in one needs npm to exist;
        # the version is nixpkgs' default rather than a pin, because nothing
        # here is built against a node ABI.
        pkgs.nodejs

        # For unpacking an extension that did not come from this file --
        # a .crx or a release zip fetched at runtime.
        pkgs.unzip
      ];

      # Fill dAppwright's cache at boot, so the first dapp test of the day is
      # not also a download. Idempotent and cheap: if the marker is there,
      # this exits without touching anything.
      #
      # A unit rather than a tmpfiles rule because the copy has to happen
      # before the marker is written -- a half-copied extension with a
      # `.success` beside it is worse than no cache at all -- and tmpfiles has
      # no way to express that ordering.
      #
      # /tmp survives reboots on this guest (boot.tmp.cleanOnBoot is off and
      # /tmp is on the ext4 root, not a tmpfs), so in practice this runs its
      # copy once per disk. It is wanted at boot anyway for the case where
      # something cleaned it.
      systemd.services.dappwright-cache = {
        description = "Pre-fill dAppwright's MetaMask cache";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          marker=${dappwrightCacheDir}/.success
          if [ -e "$marker" ]; then
            echo "Cache already present at ${dappwrightCacheDir}."
            exit 0
          fi

          # Staged and moved, the same shape as the flake drop box on the
          # host: a directory dAppwright might be reading is never a
          # directory half-written.
          rm -rf ${dappwrightCacheDir}.new
          mkdir -p ${dappwrightCacheDir}.new
          cp -rT --no-preserve=mode,ownership ${metamask} ${dappwrightCacheDir}.new
          chmod -R u+w ${dappwrightCacheDir}.new
          touch ${dappwrightCacheDir}.new/.success

          rm -rf ${dappwrightCacheDir}
          mkdir -p "$(dirname ${dappwrightCacheDir})"
          mv ${dappwrightCacheDir}.new ${dappwrightCacheDir}

          # dAppwright runs as the brain, not as root -- and it writes
          # siblings of the cache, so this is the whole root rather than the
          # version directory.
          chown -R claude:users ${dappwrightRoot}
          chmod 0755 ${dappwrightRoot}
          echo "Seeded ${dappwrightCacheDir} from ${metamask}."
        '';
      };

      # A browser with no fonts renders text as nothing, which reads as a
      # broken page rather than a missing package. Nothing else in this guest
      # ever needed them: the X server here has only run a game.
      fonts = {
        enableDefaultPackages = true;
        packages = with pkgs; [
          dejavu_fonts
          liberation_ttf
          noto-fonts
          noto-fonts-color-emoji
        ];
      };

      # Both places, for the reason ./gpu.nix states about DISPLAY:
      # sessionVariables reaches a console login, globalEnvironment reaches
      # anything systemd starts. A Playwright script that cannot find a
      # browser is the single most common way this setup fails, and it fails
      # at launch rather than at import, so the variable has to be present
      # wherever the script might run from.
      environment.sessionVariables = {
        PLAYWRIGHT_BROWSERS_PATH = "${browsers}";
        PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
        # npm's own playwright downloads browsers on install unless told not
        # to. They would be the wrong ones anyway -- the nixpkgs bundle above
        # is what is patched to run here.
        PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
        # So a script never has to know this file's store path to find the
        # extension, and so pointing it at a different one is an env var.
        WALLET_EXTENSION = "${metamask}";
        WALLET_EXTENSION_ID = extensionId;
      };

      systemd.globalEnvironment = {
        PLAYWRIGHT_BROWSERS_PATH = "${browsers}";
        PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
        # npm's own playwright downloads browsers on install unless told not
        # to. They would be the wrong ones anyway -- the nixpkgs bundle above
        # is what is patched to run here.
        PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
        WALLET_EXTENSION = "${metamask}";
        WALLET_EXTENSION_ID = extensionId;
      };
    };
}

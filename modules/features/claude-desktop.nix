# The Claude desktop app -- the GUI with the Chat, Cowork and Code tabs, as
# opposed to the CLI in claude-code.nix. Both can be installed at once; they
# share nothing but the account.
#
# Anthropic ships Linux as a Debian package only (beta, amd64/arm64), so there
# is nothing in nixpkgs to install. This takes the overlay from
# poeck/claude-desktop-nix-flake, which unpacks Anthropic's own .deb from
# downloads.claude.ai and autoPatchelfs the Electron binary. Pinned through our
# flake.lock like any other input, so a new upstream version only arrives on a
# `nix flake update`; the app does not update itself on Linux.
{ self, inputs, ... }: {
  flake.nixosModules.claude-desktop = { pkgs, ... }: {
    # Built against our nixpkgs rather than the one the flake pins, same as
    # claude-code.nix, so we don't instantiate a second nixpkgs.
    nixpkgs.overlays = [
      inputs.claude-desktop.overlays.default

      # The flake pins 2.9939.4 (its last commit is 2026-09-28, and its hourly
      # updater has not produced one since), while Anthropic ships a new build
      # every few days, so take the .deb straight from the apt pool and keep
      # only the flake's packaging. Delete this overlay once a `nix flake
      # update` brings a version at least as new as the one here.
      #
      # To bump, read Version/SHA256 for amd64 out of the repository index:
      #
      #   curl -s https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages
      #   nix hash convert --hash-algo sha256 --to sri <the hex SHA256>
      #
      # The packaging rewrites paths inside the app's minified JS and `die`s
      # when a pattern stops matching, so a version it cannot handle fails the
      # build rather than producing an app with a broken Cowork tab.
      (final: prev: {
        claude-desktop = prev.claude-desktop.overrideAttrs (old: rec {
          version = "2.42304.0";

          # New in this version, and so not in the flake's library list:
          # claude-native-binding.node links libpipewire, and autoPatchelf
          # fails the build outright over a dependency it cannot resolve.
          # autoPatchelf writes it into the .node's RPATH, so it does not also
          # need to be on the wrapper's LD_LIBRARY_PATH.
          buildInputs = old.buildInputs ++ [ final.pipewire ];
          src = final.fetchurl {
            # amd64 only: every host importing this is x86_64. On aarch64 drop
            # the overlay and take whatever the flake pins.
            url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${version}_amd64.deb";
            hash = "sha256-dM0szCnSQWUUTkVcvIcsbMKiSiY7g+c0IOlfiRZtSqQ=";
          };
        });
      })
    ];

    # Unfree, like Claude Code: hosts importing this need allowUnfree.
    environment.systemPackages = [ pkgs.claude-desktop ];

    # Cowork -- the tab that runs longer agentic work -- does it inside a VM the
    # app starts itself with QEMU/KVM. Two things it needs that the app cannot
    # arrange for itself:
    #
    #   - /dev/vhost-vsock, which is how it talks to that VM. Only the kvm group
    #     can open it, hence matthew being in kvm on hosts importing this.
    #   - the vhost_vsock module, which is not autoloaded by opening the device.
    #
    # The app checks both once at launch, so a switch that adds them wants the
    # app restarted (and joining the group wants a fresh login). QEMU itself and
    # the OVMF firmware come from the overlay's wrapper, not from here.
    boot.kernelModules = [ "vhost_vsock" ];
  };
}

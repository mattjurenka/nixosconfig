{ ... }: {
  # A playable, screenshot-able Valheim client inside the brain VM, on a
  # virtual screen. Software-rendered when this landed; hardware-rendered on
  # the host's GPU since ./gpu.nix, which owns that half and is where the
  # display itself now comes from.
  #
  # The point is `verse`. SpecZdoBody.cs is validated against the *server's*
  # serialiser, which is half the protocol; a real client on a real connection
  # gives the other half -- the live wire traffic as a player produces it, the
  # RoutedRPC exchanges, and the ZDO ownership handoffs the
  # "server-owns-shared-areas" design hinges on. None of that comes out of
  # reading IL.
  #
  # Requested and written by the brain itself (2026-10-10, through
  # /mnt/outbox/valheim-client); the rationale is its, the verification ours --
  # the same split as the mono/dotnet packages in ./configuration.nix. Four
  # corrections were made on the way in, each marked CORRECTION below, because
  # the guest cannot evaluate its own config and shipped this unrun.
  #
  # Egress was untouched when this landed, and is not any more. The original
  # plan was to log in on the host and run Steam offline against a copied
  # session, because Steam's connection manager cannot be allowlisted by domain
  # -- it needs TCP 27014-27050 as well as 443 and ignores HTTPS_PROXY for its
  # own protocol, which the brain measured rather than assumed
  # (steamcommunity.com and api.steampowered.com both 403 from the proxy while
  # api.github.com returns 200). The offline-session route turned out not to
  # survive the dedicated server's own anonymous login at every start.
  #
  # So as of 2026-10-10 the guest has a real route instead, granted on the host
  # as my.agentVms.instances.brain-vm.routedEgress: Valve's AS32590 prefixes,
  # the Steam ports, a resolver scoped to the Steam domains, and nothing else.
  # The reasoning and what it costs are written out there, next to the grant,
  # rather than here.
  #
  # Widened once more the same evening, after the brain got a real CM login and
  # measured what was still being refused: steamserver.net, steamcontent.com
  # and steamstatic.com are allowed through the proxy as subdomain trees
  # (allowedDomainSuffixes). The content CDN is in that list now -- the earlier
  # refusal was about putting Akamai/Cloudflare *addresses* in an nftables
  # rule, which would have been enormous; allowing the names through a CONNECT
  # proxy is narrower, and it is what makes a depot update and the client
  # bootstrap possible at all. The route stays Valve-only.
  #
  # What this accepts, stated plainly because it is a real widening of what
  # lives in the guest: a full-account Steam session. Steam has no scoped
  # tokens, so that session is library, friends, wallet and purchase ability,
  # and it is the one credential here scoped to nothing. The risk direction is
  # inward -- toward the Graph token and the two PATs already in
  # /var/lib/second-brain -- rather than outward, and host/stage-valheim.sh
  # chmods the session owner-only, which is as much as can be done from where
  # it sits.
  flake.modules.nixos.brainVmValheim = { pkgs, ... }: {
    # The Steam *client*, not just the package. steamwebhelper and friends are
    # 32-bit, so this needs the 32-bit library set and the FHS wrapper; the
    # bare package starts and then dies looking for ld-linux.so.2. Valheim
    # itself is 64-bit. steam-run is already in ./configuration.nix for the
    # dedicated server, and unfree is already allowed there for Claude Code.
    #
    # Nothing should be listening in a guest whose whole job is to have no
    # inbound surface, so both firewall openings stay shut.
    programs.steam = {
      enable = true;
      remotePlay.openFirewall = false;
      dedicatedServer.openFirewall = false;
    };

    # /dev/dri/card0 in the guest was bochs-drm (PCI 1234:1111) -- the dumb
    # QEMU framebuffer, with no 3D at all, so everything rendering here was
    # CPU: llvmpipe for GL, lavapipe for Vulkan. Since ./gpu.nix card0 is a
    # virtio-gpu with a native amdgpu context behind it, and GL is radeonsi
    # and Vulkan is RADV, both running on the host's Radeon 840M. llvmpipe
    # and lavapipe are still installed below and are still what a process
    # gets if it asks for software by name (LIBGL_ALWAYS_SOFTWARE=1), which
    # makes them the A/B test when something renders wrong rather than slow.
    #
    # enable32Bit is for the 32-bit Steam client's own GL, not for the game;
    # it is the 32-bit mesa that gets the accelerated drivers too.
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    # CORRECTION 1. The handoff also set boot.kernelModules, users.groups.uinput
    # and a services.udev.extraRules line by hand. hardware.uinput.enable
    # already does all three (nixos/modules/hardware/uinput.nix), and its rule
    # is the stricter one -- it matches SUBSYSTEM=="misc" as well as the kernel
    # name, where the hand-written rule matched on name alone. Duplicate udev
    # rules both apply, so the loose one would have been a silent widening for
    # no gain.
    hardware.uinput.enable = true;

    # Valheim locks the cursor and reads relative motion. Unity's legacy input
    # reads the X pointer, which xdotool's XTEST path drives fine, but a build
    # reading XInput2 raw events ignores synthetic events entirely. uinput
    # creates a real evdev device in the kernel that nothing can tell from
    # hardware, so drive.py --backend uinput is the fallback. Granted now
    # rather than later so that discovering XTEST does not work costs a flag
    # instead of a rebuild and a reboot.
    users.users.claude.extraGroups = [ "input" "uinput" ];

    environment.systemPackages = with pkgs; [
      # The X client tooling. xorgserver carries both the real server
      # ./gpu.nix runs on the virtio-gpu and the Xvfb that preceded it --
      # Xvfb is kept deliberately, as the way to reproduce a bug without the
      # GPU in the picture, not as the display anything should use: it has no
      # DRI at all, so GLX on it is llvmpipe whatever hardware is present.
      # openbox is here because Unity needs a focused window before input
      # lands anywhere.
      xorg.xorgserver
      xorg.xauth
      xorg.xrandr
      xorg.xdpyinfo
      openbox

      # GL and Vulkan. On this nixpkgs revision mesa is the split
      # package (mesa / mesa-libgbm / mesa-gl-headers) and carries the Gallium
      # drivers -- radeonsi and virgl for the accelerated paths, llvmpipe and
      # lavapipe for the software fallback -- among them; the pre-split
      # spelling was mesa.drivers. mesa-demos is for glxinfo: prove GL works,
      # and that `direct rendering` says Yes, before blaming Valheim for
      # anything. glmark2 in ./gpu.nix is the same check with a number.
      mesa
      libglvnd
      mesa-demos
      vulkan-loader
      vulkan-tools

      # Capture. imagemagick's `import` and scrot for frames, ffmpeg's x11grab
      # for short clips.
      imagemagick
      scrot
      ffmpeg

      # Input. xdotool is the primary path, evtest for debugging the uinput
      # fallback when it is not.
      xdotool
      evtest

      # CORRECTION 2. The handoff listed python3Packages.evdev here, which
      # would not have worked: python3 on this guest's PATH is the
      # withPackages environment from ./configuration.nix, and a bare
      # python3Packages derivation in systemPackages is not importable from it.
      # drive.py does `from evdev import UInput, ecodes` under
      # `#!/usr/bin/env python3`, so evdev belongs in that environment instead
      # and has been added there. This is the ModuleNotFoundError gotcha the
      # handoff's own README warns about, landing on the handoff.
    ];

    # CORRECTION 3. The handoff also set nixpkgs.config.allowUnfreePredicate to
    # a five-name allowlist. Dropped as dead code: ./configuration.nix already
    # sets allowUnfree = true for Claude Code, and check-meta.nix short-circuits
    # on that (`hasDeniedUnfreeLicense = if allowUnfree then _: false`), so the
    # predicate is never consulted. It was written to "extend the existing
    # predicate" -- but there is no existing predicate to extend, which is the
    # kind of thing the guest cannot check from inside.
    #
    # CORRECTION 4 is in ./configuration.nix: the handoff predicted the store
    # image would be the first failure and said "whatever size knob your module
    # exposes needs raising". There is no such knob. useNixStoreImage builds the
    # image with mkfs.erofs sized to the closure on every launch, so a bigger
    # closure costs build time and host disk, not a configuration change.
    # diskSize there is the guest's /dev/vda, where the ~2 GB game install goes,
    # and it is unrelated.
  };
}

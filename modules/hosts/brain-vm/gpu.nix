{ ... }: {
  # The host's GPU, shared into the brain VM, and an X server that can
  # actually use it.
  #
  # Added 2026-10-11, for the Valheim client in ./valheim-client.nix. That
  # client rendered on llvmpipe, which is why `cores` in ./configuration.nix
  # was the frame-rate knob: every pixel was CPU. Measured on this host in a
  # throwaway VM off the same nixpkgs revision -- same Xorg, same glmark2
  # 2023.01 at 800x600, 4 vCPU:
  #
  #                             glmark2   terrain   GL      Vulkan
  #   llvmpipe                      570    12 FPS   4.6sw   lavapipe
  #   virtio-gpu-gl (virgl)        1759   330 FPS   4.3     lavapipe
  #   + drm_native_context=on      2240   307 FPS   4.6     RADV (native)
  #
  # Measured back-to-back in one sitting, so the three rows are comparable to
  # each other; the absolute numbers are not portable, because they move with
  # whatever else the host is doing. The same native-context config scored 374
  # later the same day with this VM busy and the host at a load average of 7,
  # against 12 FPS on terrain for llvmpipe -- the ratio survives, the score
  # does not.
  #
  # `terrain` is the number that matters: it is the only scene with a shader
  # load like a real game's, and it is ~25x. The other scenes are nearly free
  # on a CPU too, which is why the headline score understates the change --
  # and why virgl and native context look so close. They are: for GL alone
  # either would do. What native context adds is GL 4.6 instead of 4.3 and a
  # hardware Vulkan device instead of lavapipe, both of which Unity can ask
  # for, so the choice costs nothing and removes two ceilings.
  #
  # Nothing is *passed through* in the VFIO sense, and nothing could be. This
  # machine has one GPU -- the Radeon 840M in the APU, gfx1153 -- and it is
  # driving the host's own screen. What the guest gets is a virtio-gpu device
  # whose command stream the host executes on that GPU, alongside the
  # compositor. The guest cannot take the device away from the host, and the
  # host-side unit's CPUWeight/IOWeight already express which of the two is
  # allowed to be slow.
  #
  # What this accepts, stated plainly because it is the largest widening of
  # this boundary since the Steam session. `drm_native_context=on` means the
  # guest's own mesa -- radeonsi and RADV, the same drivers the host runs --
  # submits amdgpu command streams that virglrenderer forwards to the host's
  # amdgpu driver with very little translation in between. The attack surface
  # is therefore the host kernel's GPU driver and virglrenderer, reached from
  # guest userspace, and virglrenderer's own build calls this renderer
  # `amdgpu-experimental`. That is a worse boundary than the one the rest of
  # this file's siblings describe, and it is the reason the alternatives are
  # written out below rather than left for someone to rediscover:
  #
  #   venus=true          instead of drm_native_context=on. Vulkan goes
  #                       through a serialised Vulkan protocol rather than
  #                       raw command streams; GL stays on virgl at 4.3.
  #   neither             plain `-device virtio-gpu-gl`. virgl only: GL 4.3,
  #                       no hardware Vulkan, no blob resources, the smallest
  #                       surface of the three and still ~25x on terrain.
  #
  # Each is a one-line change here and needs no change in the guest; mesa
  # picks its driver from the capsets the device advertises.
  flake.modules.nixos.brainVmGpu = { pkgs, lib, ... }:
    let
      # Root owns the X server, so the cookie is what lets `claude` -- and
      # therefore Valheim, xdotool and scrot -- talk to it. 0644 in a
      # single-user appliance whose only other account is root: the VM is the
      # boundary, not this file. The alternative is `-ac`, which turns access
      # control off outright, and there is no reason to prefer that.
      xauthority = "/run/brain-display/Xauthority";
    in
    {
      # mkAfter is load-bearing, not tidiness. `graphics = false` in
      # ./configuration.nix contributes `-nographic`, which sets the display
      # to none, and QEMU takes the *last* display option on the command line
      # -- so these have to land after it or the display is none again by the
      # time virtio-gpu-gl realizes, and QEMU exits with "The display backend
      # does not have OpenGL support enabled". Without mkAfter the order is
      # whatever the module merge happens to produce: it came out right for
      # this guest and wrong for a test guest that imported this module first,
      # which is not a thing to leave to luck.
      virtualisation.qemu.options = lib.mkAfter [
        # The emulated VGA goes away, so /dev/dri/card0 is the virtio-gpu
        # rather than bochs-drm and nothing has to guess which device is the
        # real one. The guest's consoles are ttyS0 and hvc0..hvc2 either way
        # -- see `graphics` in ./configuration.nix -- so none is lost with it.
        # Dropping the VGA does leave the VTs without a framebuffer until
        # virtio_gpu loads, which is why tty7 below is ordered by a restart
        # loop rather than assumed present.
        "-vga none"

        # blob=true plus a host memory window is what lets a guest buffer be
        # host memory the GPU can read directly, instead of being copied
        # across the virtio queue every frame; it is a requirement of native
        # context rather than a tuning knob. 4G is address space in the
        # guest's 64-bit PCI window, not a reservation: the pages are the
        # guest's own GPU allocations, charged to QEMU as they are made --
        # which is why `memorySize` dropped when this landed. See
        # my.agentVms.instances.brain-vm.memoryMax on omni-laptop.
        #
        # xres/yres set the virtual connector's preferred mode, which is the
        # resolution Xorg comes up at. The one knob worth turning here.
        "-device virtio-gpu-gl,blob=true,hostmem=4G,drm_native_context=on,xres=1280,yres=720"

        # virtio-gpu-gl refuses to realize unless the display backend can give
        # QEMU an OpenGL context, so a backend is not optional even though
        # nobody is looking. egl-headless renders into GBM buffers on the
        # render node and opens no window, needs no X or Wayland session on
        # the host -- which matters, because this VM is a systemd service with
        # no session of its own -- and exposes no SPICE or VNC port. The
        # `graphics = false` claim in ./configuration.nix is still true in the
        # sense that matters: there is no host-side window onto this guest.
        #
        # Named explicitly rather than left to auto-detection: the host has
        # exactly one render node, and if it ever has two, "whichever QEMU
        # found first" is not a thing to debug on a Friday.
        "-display egl-headless,rendernode=/dev/dri/renderD128"
      ];

      # Naming the mode is not belt-and-braces: xres/yres on the device put
      # 1280x720 in the virtual connector's EDID, but it lands there *beside*
      # 1024x768 and both come back flagged preferred, so Xorg picked the
      # smaller one. Measured with `xrandr -q` in the guest, whose mode list
      # runs to 5120x2160 -- so this is a choice rather than a limit, and a
      # different one means changing this and xres/yres together.
      #
      # This option rather than services.xserver.resolutions directly:
      # qemu-vm.nix sets that one with mkVMOverride, which outranks an
      # ordinary definition, so setting it here would silently lose. Its own
      # description claims it is "relevant only if virtualised machine uses
      # grub bootloader", which is not true of this path -- it is also what
      # feeds the X screen's Modes line.
      virtualisation.resolution = { x = 1280; y = 720; };

      # Nothing else in the guest pulls this in -- useNixStoreImage means the
      # initrd's module set is built from the filesystems, and the GPU is not
      # one. udev would autoload it from the modalias, but then the X server
      # below is racing udev at boot, and losing that race looks like "no
      # screens found" rather than "too early".
      boot.kernelModules = [ "virtio_gpu" ];

      # Not a desktop: this enables the X *configuration* -- /etc/X11/xorg.conf
      # with a ModulePath the server can find modesetting in, xkb, fonts --
      # without a display manager. startx is how NixOS spells "no display
      # manager, something else starts the server", and that something is the
      # unit below.
      #
      # modesetting rather than the amdgpu DDX: the device the guest sees is a
      # virtio-gpu, and the acceleration is glamor on top of it. Pinning the
      # list also keeps xf86-video-amdgpu and friends out of the closure,
      # where they would only be wrong answers for a probe to find.
      services.xserver = {
        enable = true;
        videoDrivers = [ "modesetting" ];
        displayManager.startx.enable = true;
      };

      # The screen. Xvfb is not an option here and that is the whole point of
      # this file: it is a software framebuffer with no DRI at all, so GLX on
      # it is llvmpipe no matter what hardware is present. A real X server on
      # the virtio-gpu's KMS node is what makes `direct rendering: Yes` true,
      # and it keeps every tool in ./valheim-client.nix working unchanged --
      # openbox, xdotool, scrot, import, ffmpeg's x11grab -- because it is
      # still an X display, just one that is wired to a GPU.
      systemd.services.brain-display = {
        description = "Headless X server on the virtio-GPU";
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "simple";
          RuntimeDirectory = "brain-display";
          RuntimeDirectoryMode = "0755";

          ExecStartPre = pkgs.writeShellScript "brain-display-auth" ''
            rm -f ${xauthority}
            ${pkgs.xauth}/bin/xauth -f ${xauthority} \
              add :0 . "$(${pkgs.util-linux}/bin/mcookie)"
            chmod 0644 ${xauthority}
          '';

          # A real VT as stdin, which is the whole reason this unit looks the
          # way it does. Xorg wants a console to own, and a unit started by
          # systemd has none by default; what that costs is not a startup
          # failure but a liar of a bug. The server comes up, answers
          # `glxinfo` and `xdpyinfo` perfectly, and then dies with
          # `xf86OpenConsole: Switching VT failed` at the moment the first
          # client maps a window -- so the symptom is a game that will not
          # start and a display that was "working a second ago", with
          # Restart=always quietly putting up a fresh server each time.
          # Measured here: 0 restarts until glxgears ran, a fatal error in
          # Xorg.brain.log at exactly that second.
          #
          # `-keeptty` is not enough on its own -- it means "use the tty I
          # already have", and the whole problem is that there is not one.
          # This is the same shape as the brain-console units in
          # ./configuration.nix, which hand a shell /dev/hvcN the same way --
          # there are three of them now, generated from `vm.consoleIndices`.
          # The VTs and the virtio consoles do not overlap: those own hvc0,
          # hvc1 and hvc2, the autologin getty owns tty1, and this owns tty7.
          #
          # vt7 rather than vt1 because tty1 belongs to the autologin getty,
          # and two things cannot own one VT; 7 is where an X server has
          # conventionally lived for exactly this reason.
          StandardInput = "tty";
          TTYPath = "/dev/tty7";
          TTYReset = true;
          TTYVHangup = true;

          # -noreset keeps the server up when the last client exits, so
          # quitting Valheim does not take the display -- and with it the
          # window manager and any capture in flight -- down with it.
          ExecStart = lib.concatStringsSep " " [
            "${pkgs.xorg-server}/bin/Xorg :0"
            "-auth ${xauthority}"
            "-noreset"
            "-logfile /var/log/Xorg.brain.log"
            "vt7"
          ];

          # The GPU appears when udev loads virtio_gpu, which can be after
          # this unit's first attempt. Restarting is the cheap way to order
          # against a device without systemd-udev-settle in the boot path.
          Restart = "always";
          RestartSec = "2s";
        };
      };

      # Set in both places for the reason ./configuration.nix writes out at
      # length for the proxy variables: sessionVariables reaches the console
      # login, globalEnvironment reaches the heartbeat and anything else
      # running as a service. A guest with exactly one screen should not make
      # anything guess its name.
      #
      # One consequence worth knowing before it surprises someone: a set
      # DISPLAY is how a CLI decides it can open a browser, so a tool that
      # wants one -- `claude` during an OAuth login, xdg-open -- will now try.
      # There is no browser installed in here, so each falls back to printing
      # the URL as before, which is the behaviour the console login depends
      # on. If a login ever stops printing a URL, this is the variable to
      # unset first.
      environment.sessionVariables = {
        DISPLAY = ":0";
        XAUTHORITY = xauthority;
      };

      systemd.globalEnvironment = {
        DISPLAY = ":0";
        XAUTHORITY = xauthority;
      };

      # Same reasoning as mesa-demos next door: prove the GPU works, with a
      # number, before blaming Valheim for anything. The figures in the table
      # above are this benchmark, so a rerun is comparable.
      environment.systemPackages = [ pkgs.glmark2 ];
    };
}

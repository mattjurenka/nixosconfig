{ ... }: {
  flake.nixosModules.mouse = { lib, config, ... }:
    let
      cfg = config.my.mouse;
    in
    {
      options.my.mouse = {
        targetDpi = lib.mkOption {
          type = lib.types.ints.positive;
          default = 800;
          example = 1600;
          description = ''
            The DPI every mouse should *feel* like: the constant you are
            holding fixed so that a given physical hand movement always
            travels the same distance on screen, whichever mouse is plugged
            in. Nothing here changes the mouse's real hardware DPI; the
            compositor scales the deltas it receives instead.
          '';
        };

        hardwareDpi = lib.mkOption {
          type = lib.types.ints.positive;
          default = cfg.targetDpi;
          example = 1200;
          description = ''
            The real, physical DPI (CPI) of the mouse used on this host.

            A mouse cannot be asked for this over USB HID — it only ever
            reports counts, never counts per inch — so it has to be supplied
            by hand from the mouse's spec sheet or its configuration software.

            Defaults to <option>my.mouse.targetDpi</option>, which scales by
            1.0 and so leaves pointer motion untouched.
          '';
        };

        accelSpeed = lib.mkOption {
          type = lib.types.float;
          readOnly = true;
          description = ''
            The libinput flat-profile `accel-speed` that turns
            <option>hardwareDpi</option> into <option>targetDpi</option>.

            libinput's flat profile scales raw device deltas by
            `max(0.005, 1 + accel-speed)` and, unlike the adaptive profile,
            never divides by the device DPI, so the ratio of the two DPIs is
            the whole calculation. Read by the niri module.
          '';
          default = (cfg.targetDpi * 1.0) / cfg.hardwareDpi - 1.0;
          defaultText = lib.literalExpression "targetDpi / hardwareDpi - 1.0";
        };
      };

      config = {
        # niri configures libinput itself; this covers anything else that goes
        # through xf86-input-libinput (an X11 session, a display manager), so
        # there is no path left on which a mouse gets accelerated.
        services.libinput = {
          mouse = {
            accelProfile = "flat";
            accelSpeed = toString cfg.accelSpeed;
          };
          touchpad = {
            accelProfile = "flat";
            accelSpeed = "0";
          };
        };

        # accel-speed is capped at 1.0, i.e. a 2x scale-up, by both libinput
        # and niri's config parser. Below half the target DPI there is simply
        # no setting that reaches it.
        assertions = [
          {
            assertion = cfg.hardwareDpi * 2 >= cfg.targetDpi;
            message = ''
              my.mouse: a ${toString cfg.hardwareDpi} DPI mouse cannot be scaled up to
              ${toString cfg.targetDpi} DPI. libinput's flat acceleration profile tops out at
              accel-speed 1.0, which is a 2x scale, so the lowest hardware DPI
              that can reach ${toString cfg.targetDpi} is ${toString ((cfg.targetDpi + 1) / 2)}.
              Raise the mouse's DPI in hardware, or lower my.mouse.targetDpi.
            '';
          }
        ];
      };
    };
}

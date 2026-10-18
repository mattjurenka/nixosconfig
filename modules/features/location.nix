# Where this machine is, as coordinates.
#
# Three separate things want to know: noctalia's night light, which ramps the
# screen's colour temperature either side of sunset; the sun-following backlight
# curve in adaptive-display.nix; and noctalia's weather widget. Giving them one
# option to read means the gamma ramp and the brightness ramp can never end up
# disagreeing about when sunset is, which is the failure mode that would make
# the two halves of adaptive display look broken while each was behaving.
#
# Coordinates rather than noctalia's `[location].address`, which it has to
# geocode over the network before the night light has a schedule at all. These
# are needed on every cold boot, by a feature whose whole job is to be correct
# the moment the screen lights up.
{ ... }: {
  flake.modules.homeManager.location = { lib, ... }: {
    options.my.location = {
      latitude = lib.mkOption {
        type = lib.types.float;
        default = 33.4484;
        example = 31.2304;
        description = ''
          Degrees north of the equator; negative for the southern hemisphere.

          The default is Phoenix, to agree with the `time.timeZone =
          "America/Phoenix"` that every host in this tree sets. noctalia's
          `[location]` previously read "Shanghai, China", which is where these
          coordinates came from until the night light started depending on
          them -- a wrong place is harmless to a weather widget and inverts
          adaptive display completely, because it puts sunset twelve hours out.
        '';
      };

      longitude = lib.mkOption {
        type = lib.types.float;
        default = -112.0740;
        example = 121.4737;
        description = ''
          Degrees east of Greenwich; negative for the western hemisphere.

          Note the sign convention: this is the one the solar position maths in
          adaptive-display.nix and noctalia both use, but half of the
          English-speaking world writes its own longitude as a positive number
          followed by a "W". Phoenix is -112, not 112.
        '';
      };
    };
  };
}

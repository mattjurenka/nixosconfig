# Backlight that follows the sun, and the single writer of the backlight.
#
# This laptop has no ambient light sensor -- no /sys/bus/iio device, no
# ACPI0008, and although `amd_sfh` is loaded it is only there as an `amd_pmf`
# dependency, the sensor fusion hub's MP2 endpoint (1022:164a/15e4) being
# absent from the bus. Firmware-side auto brightness is out too; amd-pmf logs
# "No Smart PC policy present". So the input is the sun's position, computed
# from a pair of coordinates and the clock.
#
# Colour warmth is deliberately NOT handled here. noctalia already ramps gamma
# over an hour either side of sunset through its own wlr-gamma-control client,
# driven from the same coordinates, so a second gamma client here would only
# fight it.
#
# The bar widget does not set the backlight itself; it writes a mode into the
# state file below and this loop acts on it. One writer means the curve and the
# preset buttons can never race each other for the panel.

latitude=@latitude@
longitude=@longitude@

# The two ends of the curve, as a fraction of the panel's raw range.
dayBrightness=@dayBrightness@
nightBrightness=@nightBrightness@

# Also the "min" preset, and the floor under every value this writes. It is
# deliberately above zero: a 0 here is a black screen whose only way back is
# the thing that just set it.
minBrightness=@minBrightness@

# Solar elevation in degrees at which each end of the curve is reached.
dayElevation=@dayElevation@
nightElevation=@nightElevation@

intervalSeconds=@intervalSeconds@

stateDir="${XDG_RUNTIME_DIR:-/tmp}/adaptive-display"
modeFile="$stateDir/mode"

# How far the backlight must sit from our last write before we read it as a
# person having moved it rather than as rounding.
nudgeThreshold=0.02

# How far the target must move before we bother writing. At 1% of the range
# this is roughly one write a minute through the steepest part of a twilight
# ramp, and none at all through the middle of the day or the night.
writeThreshold=0.01

mkdir -p "$stateDir"

# Degrees above the horizon, by the low-precision algorithm from the
# Astronomical Almanac. It is good to a few hundredths of a degree, which is
# far finer than a brightness curve can notice, and needs no almanac data and
# no network -- just the clock and the coordinates.
sunElevation() {
  awk -v ts="$1" -v lat="$latitude" -v lon="$longitude" '
    function rad(d) { return d * 3.14159265358979 / 180 }
    function deg(r) { return r * 180 / 3.14159265358979 }
    function wrap(x, m) { x = x - m * int(x / m); return (x < 0) ? x + m : x }
    # awk has no asin; atan2 against the adjacent side is the identity for it.
    function asin_(x) { return atan2(x, sqrt(1 - x * x)) }

    BEGIN {
      # Days since the J2000.0 epoch. The 2440587.5 term converts a unix
      # timestamp to a Julian date.
      d = ts / 86400.0 + 2440587.5 - 2451545.0

      L      = wrap(280.460 + 0.9856474 * d, 360)   # mean longitude
      g      = wrap(357.528 + 0.9856003 * d, 360)   # mean anomaly
      lambda = L + 1.915 * sin(rad(g)) + 0.020 * sin(rad(2 * g))
      eps    = 23.439 - 0.0000004 * d               # obliquity of the ecliptic

      dec = asin_(sin(rad(eps)) * sin(rad(lambda)))
      ra  = deg(atan2(cos(rad(eps)) * sin(rad(lambda)), cos(rad(lambda))))

      # Greenwich mean sidereal time, then the local hour angle.
      gmst = wrap(18.697374558 + 24.06570982441908 * d, 24)
      ha   = wrap(gmst * 15 + lon - ra + 180, 360) - 180

      sinElevation = sin(rad(lat)) * sin(dec) + cos(rad(lat)) * cos(dec) * cos(rad(ha))
      printf "%.4f\n", deg(asin_(sinElevation))
    }
  '
}

# Elevation -> brightness, smoothstepped so the ramp has no kink where it meets
# either flat end. A plain linear interpolation is visible as a change in the
# rate of dimming right at sunset, which reads as the screen flinching.
brightnessFor() {
  awk -v e="$1" \
      -v lo="$nightElevation" -v hi="$dayElevation" \
      -v nb="$nightBrightness" -v db="$dayBrightness" '
    BEGIN {
      t = (e - lo) / (hi - lo)
      if (t < 0) t = 0
      if (t > 1) t = 1
      printf "%.4f\n", nb + (db - nb) * (t * t * (3 - 2 * t))
    }
  '
}

# Which flat of the curve, or the ramp between them, the schedule is on now.
regimeFor() {
  awk -v t="$1" -v nb="$nightBrightness" -v db="$dayBrightness" '
    BEGIN {
      if (t >= db - 0.001) print "day"
      else if (t <= nb + 0.001) print "night"
      else print "ramp"
    }
  '
}

clampBrightness() {
  awk -v v="$1" -v floor="$minBrightness" '
    BEGIN {
      if (v < floor) v = floor
      if (v > 1.00) v = 1.00
      printf "%.4f\n", v
    }
  '
}

# The first readable sysfs backlight. Hosts that share this home and drive only
# external monitors have none, and have nothing for this to adapt.
backlight=""
for candidate in /sys/class/backlight/*; do
  if [ -r "$candidate/brightness" ] && [ -r "$candidate/max_brightness" ]; then
    backlight="$candidate"
    break
  fi
done

if [ -z "$backlight" ]; then
  echo "no sysfs backlight on this host; nothing to follow the sun with"
  exit 0
fi

device="$(basename "$backlight")"
maxRaw="$(cat "$backlight/max_brightness")"
echo "following the sun on $device (raw range 0-$maxRaw) at ${latitude},${longitude}"

# logind's SetBrightness rather than a write to sysfs, which is root-owned:
# this goes through the session's own authority, so it needs no udev rule and
# no group membership. noctalia keeps the backlight under inotify, so it sees
# the result and holds its slider in step without an OSD firing on every step
# of a ramp -- which is what going through `noctalia msg brightness-set` would
# have done.
applyBrightness() {
  local raw
  raw="$(awk -v v="$1" -v m="$maxRaw" 'BEGIN { printf "%d\n", int(v * m + 0.5) }')"
  busctl call org.freedesktop.login1 /org/freedesktop/login1/session/auto \
    org.freedesktop.login1.Session SetBrightness ssu \
    backlight "$device" "$raw" >/dev/null 2>&1
}

readNormalized() {
  # `brightness` rather than `actual_brightness`: this panel reports a lower
  # `actual_brightness` than was ever requested (39321 set, 32718 read back),
  # because the firmware dims on its own. `brightness` is the requested value,
  # and the only one that reflects an intent worth respecting.
  awk -v r="$(cat "$backlight/brightness")" -v m="$maxRaw" 'BEGIN { printf "%.4f\n", r / m }'
}

# What the person has added to or taken off the curve by hand, and the state
# needed to notice them doing it. `lastTarget` is the curve's own value before
# the offset, which is what a manual setting is a deviation *from*.
offset=0
regime=""
lastSet=""
lastTarget=""
lastNonce=""

while :; do
  # Arm the watch before reading any state rather than after acting on it.
  # inotifywait only reports what arrives once it is already running, so
  # starting it at the foot of the loop drops anything that lands during the
  # work -- and a dropped press then waits out the whole interval before it is
  # noticed. Arming first means a change made while we were busy is already
  # queued by the time we come to wait on it.
  #
  # `moved_to` only: the helper writes through a temporary file and renames it,
  # so the rename is the single event per press. Watching `create` as well
  # would fire on the temporary file too, waking this loop to re-read a mode
  # file that had not changed yet.
  inotifywait -q -q -t "$intervalSeconds" -e moved_to "$stateDir" >/dev/null 2>&1 &
  watcher=$!

  # Every write to the mode file carries a fresh nonce, so pressing the preset
  # that is already selected still counts as an instruction. Without it, a
  # button would go dead exactly when it was most wanted: after the Fn keys had
  # moved the backlight away from the preset the widget still shows as active.
  mode="adaptive"
  nonce=""
  if [ -r "$modeFile" ]; then
    read -r mode nonce < "$modeFile" || true
    [ -n "$mode" ] || mode="adaptive"
  fi

  if [ "$nonce" != "$lastNonce" ]; then
    lastNonce="$nonce"
    # A new instruction starts the adaptation from scratch rather than from
    # whatever offset the previous mode had accumulated.
    offset=0
    regime=""
    lastSet=""
    lastTarget=""

    case "$mode" in
      min)  preset="$minBrightness" ;;
      half) preset=0.5 ;;
      max)  preset=1.0 ;;
      *)    preset="" ;;
    esac

    if [ -n "$preset" ]; then
      preset="$(clampBrightness "$preset")"
      if applyBrightness "$preset"; then
        echo "mode $mode: holding at $preset"
      else
        echo "mode $mode: SetBrightness refused; leaving the backlight alone"
      fi
    fi
  fi

  if [ "$mode" = "adaptive" ]; then
    elevation="$(sunElevation "$(date +%s)")"
    target="$(brightnessFor "$elevation")"
    currentRegime="$(regimeFor "$target")"
    actual="$(readNormalized)"

    if [ "$currentRegime" != "$regime" ]; then
      # A nudge made in daylight should not still be in force at midnight, so
      # crossing into a new regime forgives it and hands the curve back.
      regime="$currentRegime"
      offset=0
    elif [ -n "$lastSet" ]; then
      # Anything that moved the backlight other than us -- the Fn keys,
      # noctalia's slider -- is a preference, not drift to be corrected. Keep
      # it as a signed offset so adaptation carries on around what was asked
      # for instead of overwriting it a minute later.
      offset="$(awk -v a="$actual" -v s="$lastSet" -v t="$lastTarget" -v o="$offset" -v thr="$nudgeThreshold" '
        BEGIN {
          drift = a - s
          if (drift < 0) drift = -drift
          if (drift <= thr) { print o; exit }
          shifted = a - t
          if (shifted >  0.9) shifted =  0.9
          if (shifted < -0.9) shifted = -0.9
          printf "%.4f\n", shifted
        }
      ')"
    fi

    apply="$(clampBrightness "$(awk -v t="$target" -v o="$offset" 'BEGIN { printf "%.4f\n", t + o }')")"

    if [ -z "$lastSet" ] || [ "$(awk -v a="$apply" -v c="$actual" -v thr="$writeThreshold" \
        'BEGIN { d = a - c; if (d < 0) d = -d; print (d > thr) ? "yes" : "no" }')" = "yes" ]; then
      if applyBrightness "$apply"; then
        echo "sun ${elevation}deg, ${currentRegime}: curve ${target}, offset ${offset} -> ${apply}"
        lastSet="$apply"
      else
        # Most likely the session is not active: another VT holds it, or it is
        # locked. Leave `lastSet` alone so the next tick retries instead of
        # mistaking the failure for someone having moved the slider.
        echo "SetBrightness refused for $device; leaving the backlight alone"
      fi
    fi

    lastTarget="$target"
  fi

  # Blocks until the mode file is replaced or the interval runs out, whichever
  # comes first, so a button press lands immediately while the sun is only
  # looked at once a minute.
  wait "$watcher" || true
done

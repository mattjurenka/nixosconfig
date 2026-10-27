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

# The overlay's end of the job, and where it reaches full strength. Below
# nightElevation the backlight has already bottomed out, so this is the only
# thing left that can make the screen darker -- see screen-dim.qml for why it
# is a black sheet rather than a gamma ramp.
nightDim=@nightDim@
dimElevation=@dimElevation@

# The blackest sheet anything here will ask for. The overlay clamps at 0.9 of
# its own accord as a last resort; this is the lower, deliberate limit that
# the curve and the Fn keys work inside.
maxDim=@maxDim@

intervalSeconds=@intervalSeconds@

stateDir="${XDG_RUNTIME_DIR:-/tmp}/adaptive-display"
modeFile="$stateDir/mode"
dimFile="$stateDir/dim"

# How far the backlight must sit from our last write before we read it as a
# person having moved it rather than as rounding.
nudgeThreshold=0.02

# The same idea for the sheet. Larger than nudgeThreshold in proportion to
# the range it covers: a dim step from the Fn keys is 0.2 wide, so nothing
# smaller than that is a person.
dimNudgeThreshold=0.05

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

# Elevation -> how black a sheet to lay over the screen, for the stretch of
# twilight below where the backlight gave up. Smoothstepped like the backlight
# ramp, and starting exactly where that one ends, so the two read as one
# continuous dimming rather than as a handover between two mechanisms.
dimFor() {
  awk -v e="$1" -v lo="$dimElevation" -v hi="$nightElevation" -v maxDim="$nightDim" '
    BEGIN {
      # A window of zero or less has no ramp in it. Treat it as a step at the
      # bottom rather than dividing by it, which would put a nan in the file
      # the overlay reads.
      if (hi - lo <= 0) { printf "%.4f\n", (e <= lo) ? maxDim : 0; exit }

      t = (e - lo) / (hi - lo)
      if (t < 0) t = 0
      if (t > 1) t = 1
      printf "%.4f\n", maxDim * (1 - (t * t * (3 - 2 * t)))
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

# The overlay reads this file and nothing else, so this is the whole of the
# interface between the two halves of the dimming.
#
# Written in place rather than through a temporary file and a rename, which is
# what the mode file does: the overlay holds a watch on this path, and
# replacing the inode under it takes the watch with it. The cost is that a
# read can land in the gap between the truncate and the write; the overlay
# treats an unparseable value as "caught mid-write" and keeps the last good
# one, and the write it was caught in the middle of arrives as another change
# a moment later.
applyDim() {
  if [ -z "$lastDim" ] || [ "$(awk -v a="$1" -v b="$lastDim" \
      'BEGIN { d = a - b; if (d < 0) d = -d; print (d > 0.005) ? "yes" : "no" }')" = "yes" ]; then
    printf '%s\n' "$1" > "$dimFile"
    # Reported here rather than alongside the backlight, because the two no
    # longer move together: once the panel is on its floor the sheet is the
    # only thing left changing, and a tick that writes one but not the other
    # would otherwise go by in silence -- which is the state of affairs this
    # log is most wanted for.
    echo "sheet ${lastDim:-none} -> $1"
    lastDim="$1"
  fi
}

readNormalized() {
  # `brightness` rather than `actual_brightness`: this panel reports a lower
  # `actual_brightness` than was ever requested (39321 set, 32718 read back),
  # because the firmware dims on its own. `brightness` is the requested value,
  # and the only one that reflects an intent worth respecting.
  awk -v r="$(cat "$backlight/brightness")" -v m="$maxRaw" 'BEGIN { printf "%.4f\n", r / m }'
}


readDim() {
  # The file may not exist yet on the first tick of a fresh session, and may
  # be caught between the truncate and the write of either writer. Both read
  # as "no sheet", which is the same answer the overlay gives itself and so
  # cannot put the two of them out of step.
  dim=0
  if [ -r "$dimFile" ]; then
    read -r raw < "$dimFile" || raw=""
    dim="$(awk -v v="$raw" 'BEGIN { print (v + 0 == v && v >= 0 && v <= 1) ? v : 0 }')"
  fi
  echo "$dim"
}

# What the person has added to or taken off the curve by hand, and the state
# needed to notice them doing it. `lastTarget` is the curve's own value before
# the offset, which is what a manual setting is a deviation *from*.
offset=0
regime=""
lastSet=""
lastTarget=""
lastNonce=""
lastDim=""
dimOffset=0
lastDimTarget=""

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
    dimOffset=0
    lastDimTarget=""

    case "$mode" in
      min)  preset="$minBrightness"; presetDim="$nightDim" ;;
      half) preset=0.5;               presetDim=0 ;;
      max)  preset=1.0;               presetDim=0 ;;
      *)    preset="";                presetDim="" ;;
    esac

    if [ -n "$preset" ]; then
      preset="$(clampBrightness "$preset")"
      # The sheet before the backlight, so a jump up to full is never seen
      # through one that is still fading out. "Minimum" means both halves now:
      # the panel at its floor and the overlay at full strength, which is as
      # dark as this machine goes.
      applyDim "$presetDim"
      if applyBrightness "$preset"; then
        echo "mode $mode: holding at $preset, dim $presetDim"
      else
        echo "mode $mode: SetBrightness refused; leaving the backlight alone"
      fi
    fi
  fi

  if [ "$mode" = "adaptive" ]; then
    elevation="$(sunElevation "$(date +%s)")"
    target="$(brightnessFor "$elevation")"
    currentRegime="$(regimeFor "$target")"
    curveDim="$(dimFor "$elevation")"
    actual="$(readNormalized)"
    actualDim="$(readDim)"

    if [ "$currentRegime" != "$regime" ]; then
      # A nudge made in daylight should not still be in force at midnight, so
      # crossing into a new regime forgives it and hands the curve back. Both
      # halves of it: the sheet is as much a preference as the backlight is,
      # and forgiving one without the other would leave the screen in a state
      # neither the person nor the curve ever asked for.
      regime="$currentRegime"
      offset=0
      dimOffset=0
    else
      if [ -n "$lastSet" ]; then
        # Anything that moved the backlight other than us -- the Fn keys,
        # noctalia's slider -- is a preference, not drift to be corrected.
        # Keep it as a signed offset so adaptation carries on around what was
        # asked for instead of overwriting it a minute later.
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

      if [ -n "$lastDim" ]; then
        # The same reading of the dim file, for the same reason. The only
        # other writer is screen-brightness, which is the Fn keys arriving
        # below the backlight's floor -- so a value here that is not the one
        # we last wrote is a person asking for it.
        dimOffset="$(awk -v a="$actualDim" -v s="$lastDim" -v t="$lastDimTarget" -v o="$dimOffset" -v thr="$dimNudgeThreshold" '
          BEGIN {
            drift = a - s
            if (drift < 0) drift = -drift
            if (drift <= thr) { print o; exit }
            printf "%.4f\n", a - t
          }
        ')"
      fi
    fi

    apply="$(clampBrightness "$(awk -v t="$target" -v o="$offset" 'BEGIN { printf "%.4f\n", t + o }')")"

    # The invariant the Fn keys are built on: the sheet exists only while the
    # backlight is on its floor. A positive offset has taken the panel off the
    # floor, and a sheet over a backlight that still has room to move would
    # make one brightness expressible two ways -- which is exactly what makes
    # a pair of keys feel broken, since the one they move need not be the one
    # the eye is reading.
    applyDimTarget="$(awk -v c="$curveDim" -v o="$dimOffset" -v a="$apply" \
        -v floor="$minBrightness" -v maxDim="$maxDim" '
      BEGIN {
        if (a > floor + 0.0005) { print "0.0000"; exit }
        v = c + o
        if (v < 0) v = 0
        if (v > maxDim) v = maxDim
        printf "%.4f\n", v
      }
    ')"

    # Outside the write-threshold test the backlight gets below: the sheet is
    # the only thing still moving once the panel has bottomed out, so a tick
    # that decides the backlight has nothing to do still has this to do.
    # applyDim does its own thresholding.
    applyDim "$applyDimTarget"

    if [ -z "$lastSet" ] || [ "$(awk -v a="$apply" -v c="$actual" -v thr="$writeThreshold" \
        'BEGIN { d = a - c; if (d < 0) d = -d; print (d > thr) ? "yes" : "no" }')" = "yes" ]; then
      if applyBrightness "$apply"; then
        echo "sun ${elevation}deg, ${currentRegime}: curve ${target}, offset ${offset} -> ${apply}, dim ${applyDimTarget}"
        lastSet="$apply"
      else
        # Most likely the session is not active: another VT holds it, or it is
        # locked. Leave `lastSet` alone so the next tick retries instead of
        # mistaking the failure for someone having moved the slider.
        echo "SetBrightness refused for $device; leaving the backlight alone"
      fi
    fi

    lastTarget="$target"
    lastDimTarget="$curveDim"
  fi

  # Blocks until the mode file is replaced or the interval runs out, whichever
  # comes first, so a button press lands immediately while the sun is only
  # looked at once a minute.
  wait "$watcher" || true
done

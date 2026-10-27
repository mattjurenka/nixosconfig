# The Fn brightness keys, across the seam where the backlight stops and the
# overlay starts.
#
# Bound instead of `noctalia msg brightness-up|down` because noctalia only
# knows about the panel, and the panel is spent at 5%: its own step takes it
# from there to 0, which on this hardware is the same light (actual_brightness
# clamps at 3084 of 65535 either way) and reads to the person as a key that
# has stopped working. Below that the only thing left that can change the
# light is the sheet in screen-dim.qml, and nothing in the shell knows it
# exists.
#
# So this presents both as one number:
#
#   E = backlight x (1 - dim)
#
# which is proportional to the light actually coming off the screen, and is
# therefore the honest thing to put in an OSD. The invariant that keeps it
# single-valued is that the sheet only exists while the backlight is on its
# floor -- there is never a choice of two ways to express one E, and raising
# the backlight necessarily takes the sheet off.
#
# Above the floor the steps are noctalia's own five points, so the keys feel
# no different from how they always have. Below it they are one point, because
# the whole range down there is five points wide and a five-point step would
# make it a single on/off.
#
# The backlight goes through logind rather than `noctalia msg brightness-set`
# for the same reason sun-brightness.sh does: noctalia watches the backlight
# and moves its slider to match without being told, so going through it would
# only add a second OSD firing underneath the one this draws deliberately.

minBrightness=@minBrightness@
maxDim=@maxDim@
coarseStep=@coarseStep@
fineStep=@fineStep@
noctalia=@noctalia@

stateDir="${XDG_RUNTIME_DIR:-/tmp}/adaptive-display"
dimFile="$stateDir/dim"

mkdir -p "$stateDir"

case "${1:-}" in
  up|down) direction="$1" ;;
  *)
    echo "usage: screen-brightness up|down" >&2
    exit 2
    ;;
esac

backlight=""
for candidate in /sys/class/backlight/*; do
  if [ -r "$candidate/brightness" ] && [ -r "$candidate/max_brightness" ]; then
    backlight="$candidate"
    break
  fi
done

if [ -z "$backlight" ]; then
  # Nothing of ours to drive on this host, but the key should still do the
  # obvious thing rather than nothing at all.
  exec "$noctalia" msg "brightness-$direction"
fi

device="$(basename "$backlight")"
maxRaw="$(cat "$backlight/max_brightness")"

readDim() {
  dim=0
  if [ -r "$dimFile" ]; then
    read -r raw < "$dimFile" || raw=""
    # An unparseable read is the truncate-and-write gap in applyDim, and the
    # right answer for a keypress landing in it is the same one the overlay
    # takes: assume no sheet rather than invent one.
    dim="$(awk -v v="$raw" 'BEGIN { print (v + 0 == v && v >= 0 && v <= 1) ? v : 0 }')"
  fi
  echo "$dim"
}

dim="$(readDim)"
backlightFraction="$(awk -v r="$(cat "$backlight/brightness")" -v m="$maxRaw" \
  'BEGIN { printf "%.4f\n", r / m }')"

# Where the axis bottoms out: the panel on its floor behind the blackest sheet
# the keys are allowed to ask for.
floorE="$(awk -v f="$minBrightness" -v d="$maxDim" 'BEGIN { printf "%.4f\n", f * (1 - d) }')"

target="$(awk \
  -v b="$backlightFraction" -v d="$dim" -v dir="$direction" \
  -v floor="$minBrightness" -v floorE="$floorE" \
  -v coarse="$coarseStep" -v fine="$fineStep" '
  BEGIN {
    e = b * (1 - d)

    # A hair of tolerance either side of the floor, so a value that is the
    # floor but for rounding takes the branch it looks like it should.
    eps = 0.0005

    if (dir == "up") {
      # Stopping at the floor on the way up rather than stepping past it keeps
      # the seam a place the axis always lands on, which is what makes the
      # next press predictable in either direction.
      step = (e < floor - eps) ? fine : coarse
      t = e + step
      if (e < floor - eps && t > floor) t = floor
      if (t > 1) t = 1
    } else {
      step = (e > floor + eps) ? coarse : fine
      t = e - step
      if (e > floor + eps && t < floor) t = floor
      if (t < floorE) t = floorE
    }

    printf "%.4f\n", t
  }
')"

# The decomposition, and the invariant it enforces: above the floor the
# backlight carries the whole value and there is no sheet; at or below it the
# backlight sits on the floor and the sheet carries the remainder.
newBacklight="$(awk -v t="$target" -v floor="$minBrightness" \
  'BEGIN { printf "%.4f\n", (t >= floor) ? t : floor }')"
newDim="$(awk -v t="$target" -v floor="$minBrightness" \
  'BEGIN { printf "%.4f\n", (t >= floor) ? 0 : 1 - t / floor }')"

printf '%s\n' "$newDim" > "$dimFile"

raw="$(awk -v v="$newBacklight" -v m="$maxRaw" 'BEGIN { printf "%d\n", int(v * m + 0.5) }')"
busctl call org.freedesktop.login1 /org/freedesktop/login1/session/auto \
  org.freedesktop.login1.Session SetBrightness ssu \
  backlight "$device" "$raw" >/dev/null 2>&1

# Drawn from the effective value rather than from the backlight, so the number
# keeps moving through the part of the range where the backlight cannot. A
# fraction rather than a percentage: noctalia reads anything at or below 1 as
# one, and the whole bottom of this axis is below 1%.
"$noctalia" msg brightness-osd "$target" >/dev/null 2>&1 || true

echo "$target"

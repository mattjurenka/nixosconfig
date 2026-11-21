# Mod+T's half of the touchpad switch, and the bar glyph's source of truth.
#
#   touchpad toggle | on | off   flip it, or set it
#   touchpad get                 print on or off
#   touchpad watch               print it, then on every change
#
# niri has no IPC for turning an input device off, and its config is in the
# store, so the switch is the kernel's own: writing 1 to an input device's
# `inhibited` stops its events before libinput ever sees them. The udev rule
# in touchpad.nix is what lets this user write there.
#
# Every input node hanging off the touchpad's HID device goes together. The
# Synaptics pad here registers a "Mouse" node beside the "Touchpad" one, and
# leaving that awake would leave half the pad working.

stateDir="${XDG_RUNTIME_DIR:-/tmp}/touchpad"
stamp="$stateDir/changed"

mkdir -p "$stateDir"

# The inhibited files of every node belonging to an internal touchpad.
nodes() {
  local dev
  for dev in /sys/class/input/input*; do
    udevadm info --query=property "$dev" 2>/dev/null | grep -qx 'ID_INPUT_TOUCHPAD=1' || continue
    ls "$(readlink -f "$dev")"/../input*/inhibited 2>/dev/null
  done | sort -u
}

current() {
  local f
  for f in $(nodes); do
    if [ "$(cat "$f")" = 1 ]; then
      echo off
      return
    fi
  done
  echo on
}

set_to() {
  local value=0 f
  [ "$1" = off ] && value=1
  for f in $(nodes); do
    echo "$value" > "$f" || echo "touchpad: cannot write $f" >&2
  done
  # sysfs never raises inotify, so `watch` hears about a change from this
  # instead. Through a rename so it arrives as moved_to, as in display-mode.
  tmp="$(mktemp "$stateDir/changed.XXXXXX")"
  date +%s%N > "$tmp"
  mv -f "$tmp" "$stamp"
}

case "${1:-}" in
  on | off)
    set_to "$1"
    ;;

  toggle)
    if [ "$(current)" = on ]; then set_to off; else set_to on; fi
    ;;

  get)
    current
    ;;

  watch)
    last=""
    while :; do
      # Armed before reading, so a change between the two is not lost. The
      # timeout catches what no toggle announced: a resume or a replug that
      # brought the pad back with a fresh, uninhibited node.
      inotifywait -q -q -t 30 -e moved_to "$stateDir" >/dev/null 2>&1 &
      watcher=$!

      state="$(current)"
      if [ "$state" != "$last" ]; then
        last="$state"
        echo "$state"
      fi

      wait "$watcher" || true
    done
    ;;

  *)
    echo "usage: touchpad {toggle|on|off|get|watch}" >&2
    exit 64
    ;;
esac

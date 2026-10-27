# Mod+S: noctalia's region screenshot, taken from under the screen-dim sheet.
#
# The sheet is composited, so any capture of the screen includes it and comes
# out as dark as the room needed the screen to be (see screen-dim.qml). So the
# sheet is hidden for the moment noctalia freezes the screen, and comes back
# as soon as noctalia's selection overlay is up -- which is how we know the
# frame has been taken, since `noctalia msg` returns before it is.
#
# The cost is a flash of the undimmed screen for that moment, and the frozen
# image noctalia shows while you pick a region is the undimmed one: its
# overlay arrives after the sheet, so it stacks above it.

dimIpc() {
  quickshell ipc -p @screenDimQml@ call screenDim "$1" >/dev/null 2>&1
}

# Surfaces that take the keyboard for themselves; the selection overlay is
# one, and nothing else on this desktop sits around holding it.
grabbers() {
  niri msg --json layers | jq '[.[] | select(.keyboard_interactivity == "Exclusive")] | length'
}

# The sheet is not running, or not dimming: nothing to get out from under.
if ! dimIpc hide; then
  exec noctalia msg screenshot-region
fi
trap 'dimIpc restore' EXIT

before=$(grabbers)
# One frame for niri to present the screen without the sheet.
sleep 0.05
noctalia msg screenshot-region

# At most two seconds: a capture that failed to open its overlay should not
# leave the screen undimmed.
for _ in $(seq 100); do
  [ "$(grabbers)" -gt "$before" ] && break
  sleep 0.02
done

# The bar widget's half of adaptive display: it names a mode, it does not set
# the backlight. sun-brightness.sh is the only writer of the panel, and it
# watches this file, so a press lands there immediately over inotify.
#
#   display-mode min | half | max | adaptive   name a mode
#   display-mode get                           print the current mode
#   display-mode watch                         print it, then on every change
#
# `watch` is what the widget streams, so the selected button also follows a
# mode set from a shell or a keybind rather than only its own clicks.

stateDir="${XDG_RUNTIME_DIR:-/tmp}/adaptive-display"
modeFile="$stateDir/mode"

mkdir -p "$stateDir"

currentMode() {
  local mode=""
  if [ -r "$modeFile" ]; then
    read -r mode _ < "$modeFile" || true
  fi
  # Nothing written yet means nothing has overridden the curve, which is the
  # mode the service runs in when left alone.
  echo "${mode:-adaptive}"
}

case "${1:-}" in
  min | half | max | adaptive)
    # The nonce is what makes re-pressing the already-selected preset do
    # something. Mode alone would be an unchanged file, no inotify event, and a
    # button that goes dead exactly when it is most wanted -- after the Fn keys
    # have moved the backlight away from the preset still shown as active.
    #
    # Written through a temporary file in the same directory so a reader can
    # never catch a half-written line: the rename is atomic, and `-e moved_to`
    # is why the service watches for it.
    tmp="$(mktemp "$stateDir/mode.XXXXXX")"
    echo "$1 $(date +%s%N)" > "$tmp"
    mv -f "$tmp" "$modeFile"
    ;;

  get)
    currentMode
    ;;

  watch)
    # One line per change, starting with the mode as it stands, so a widget
    # that has just started renders the truth rather than a default.
    last=""
    while :; do
      # Armed before the mode is read, for the same reason the service does it:
      # inotifywait reports only what arrives while it is already running, so a
      # change landing between the read and the watch would be missed -- and
      # here there is no interval to fall back on, so the widget would sit on a
      # stale mode until whatever the next press happened to be. `moved_to` is
      # the only event worth watching because every write arrives as a rename.
      inotifywait -q -q -e moved_to "$stateDir" >/dev/null 2>&1 &
      watcher=$!

      mode="$(currentMode)"
      # Only on a real change: every preset press rewrites the file with a new
      # nonce, and a widget has nothing to re-render for a press that landed on
      # the mode it is already showing.
      if [ "$mode" != "$last" ]; then
        last="$mode"
        echo "$mode"
      fi

      # Returns immediately when a change arrived while we were reading, which
      # is what arming first bought.
      wait "$watcher" || true
    done
    ;;

  *)
    echo "usage: display-mode {min|half|max|adaptive|get|watch}" >&2
    exit 64
    ;;
esac

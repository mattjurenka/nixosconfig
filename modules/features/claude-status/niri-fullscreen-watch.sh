# Streams the outputs whose screen is currently filled by a fullscreen window,
# as a JSON array of connector names, re-emitted whenever that set changes.
#
# This is what decides whether the corner dot is drawn, because niri renders a
# fullscreen window above the Top layer -- which is where noctalia's bar lives,
# so the bar (and the Claude widget in it) is gone exactly then.
#
# niri 26.04's IPC carries no fullscreen flag, so this measures instead: the
# window is fullscreen when it is exactly as large as its output's logical
# size, since every tiled or maximized window is inset by the layout gaps and
# the bar's exclusive zone. Only each output's *front* window counts -- the
# active window of its active workspace -- because niri will happily hold a
# fullscreen window in a column that is scrolled off screen, and that one
# covers nothing.

fullscreen_outputs() {
  local windows outputs workspaces
  windows=$(niri msg --json windows 2>/dev/null) || return 1
  outputs=$(niri msg --json outputs 2>/dev/null) || return 1
  workspaces=$(niri msg --json workspaces 2>/dev/null) || return 1

  jq -cn \
    --argjson windows "$windows" \
    --argjson outputs "$outputs" \
    --argjson workspaces "$workspaces" '
    ($workspaces
      | map(select(.is_active and .active_window_id != null))
      | map({ key: (.active_window_id | tostring), value: .output })
      | from_entries) as $front
    | ($outputs
      | to_entries
      | map({
          key: .key,
          value: [((.value.logical.width // 0) | round), ((.value.logical.height // 0) | round)],
        })
      | from_entries) as $size
    | [ $windows[]
        | . as $window
        | ($front[$window.id | tostring]) as $output
        | select($output != null and $size[$output] != null)
        | ($window.layout.window_size // empty) as $windowSize
        | select(($windowSize[0] | round) == $size[$output][0]
             and ($windowSize[1] | round) == $size[$output][1])
        | $output ]
    | unique
  '
}

emit() {
  local line
  line=$(fullscreen_outputs) || return 0
  if [ "$line" != "$last" ]; then
    printf '%s\n' "$line"
    last=$line
  fi
}

last=""
emit

# niri sends nothing while the layout is still, so this idles at no cost. Any
# window or workspace event can change the answer; recomputing is three cheap
# IPC round trips, which is simpler than tracking the layout incrementally.
#
# The outer loop is for a niri that restarted underneath us: the stream ends,
# and we pick the new one up instead of going quiet for the rest of the session.
while :; do
  niri msg --json event-stream 2>/dev/null | while IFS= read -r event; do
    case "$event" in
      *'"Window'* | *'"Workspace'* | *'"Overview'*) emit ;;
    esac
  done

  sleep 2
  last=""
  emit
done

# Flips the focused column between half and full width.
#
# niri has no "toggle to this width" action. maximize-column goes full width
# and back to whatever the column was before, so from a width this script did
# not set it may flip back to something other than half; switch-preset-column-width
# walks the whole preset list, which takes two or three presses to cross.
#
# So this measures instead. niri 26.04's IPC carries no fullscreen flag, and a
# real fullscreen window is exactly its output's logical size while a full-width
# column is inset by the gaps and the bar -- the same trick
# claude-status/niri-fullscreen-watch.sh uses. Anything wider than three
# quarters of the output counts as full, and the next press halves it.

window=$(niri msg --json focused-window) || exit 0
[ -n "$window" ] && [ "$window" != "null" ] || exit 0

workspace=$(jq -r '.workspace_id' <<<"$window")
connector=$(niri msg --json workspaces \
  | jq -r --argjson ws "$workspace" '.[] | select(.id == $ws) | .output')
[ -n "$connector" ] && [ "$connector" != "null" ] || exit 0

read -r outputWidth outputHeight < <(niri msg --json outputs \
  | jq -r --arg c "$connector" '.[$c].logical | "\(.width) \(.height)"')
read -r windowWidth windowHeight < <(jq -r '.layout.window_size | "\(.[0]) \(.[1])"' <<<"$window")

# A fullscreen window ignores column width entirely, so leaving fullscreen is
# what "make it smaller" means while one is up.
if [ "$windowWidth" -eq "$outputWidth" ] && [ "$windowHeight" -eq "$outputHeight" ]; then
  niri msg action fullscreen-window
  niri msg action set-column-width 50%
  exit 0
fi

if [ "$((windowWidth * 4))" -gt "$((outputWidth * 3))" ]; then
  niri msg action set-column-width 50%
else
  niri msg action set-column-width 100%
fi

# Mod+J / Mod+K: focus the window below (or above) in the column, and when
# there is none, the next (or previous) workspace instead -- wrapping from the
# last workspace back round to the first, and from the first to the last.
#
# niri's focus-window-or-workspace-down does the first half but stops at the
# ends, so this does the wrap itself. Workspaces are counted on the focused
# output, which is what focus-workspace's index means too.

direction=$1

window=$(niri msg --json focused-window)

if [ -n "$window" ] && [ "$window" != "null" ]; then
  # A floating window has no column, so it falls through to the workspace.
  neighbour=$(niri msg --json windows | jq --argjson w "$window" --arg dir "$direction" '
    ($w.layout.pos_in_scrolling_layout) as $pos
    | if $pos == null then false else
        any(.[]; .workspace_id == $w.workspace_id
          and .layout.pos_in_scrolling_layout != null
          and .layout.pos_in_scrolling_layout[0] == $pos[0]
          and (if $dir == "down"
               then .layout.pos_in_scrolling_layout[1] > $pos[1]
               else .layout.pos_in_scrolling_layout[1] < $pos[1] end))
      end')
  if [ "$neighbour" = "true" ]; then
    niri msg action "focus-window-$direction"
    exit 0
  fi
fi

read -r current last < <(niri msg --json workspaces | jq -r '
  (.[] | select(.is_focused) | .output) as $out
  | [.[] | select(.output == $out)] as $ws
  | "\($ws[] | select(.is_focused) | .idx) \([$ws[].idx] | max)"')

if [ "$direction" = "down" ]; then
  if [ "$current" -ge "$last" ]; then
    niri msg action focus-workspace 1
  else
    niri msg action focus-workspace-down
  fi
else
  if [ "$current" -le 1 ]; then
    niri msg action focus-workspace "$last"
  else
    niri msg action focus-workspace-up
  fi
fi

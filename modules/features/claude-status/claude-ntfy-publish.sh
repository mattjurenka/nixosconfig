# Publishes this laptop's reading to an ntfy topic, so a phone can poll it.
#
# What goes over the wire is deliberately thin: how many sessions there are and
# what state each one is in, and nothing that names the work. ntfy.sh is a
# public relay -- the topic name is the only thing keeping a reading private --
# and session names are the titles of conversations, which is exactly the part
# worth not publishing. The widget draws squares; it does not need them.
#
# One identifier does go over it: each session's `bridge`, the remote-control
# id behind claude.ai/code/<id>, so a square on the phone can open the session
# it stands for. It is an opaque id rather than a name, and following it still
# takes a login on the account -- but it is strictly more than counts, so it is
# worth knowing it is there.
#
# That id is also the filter, not just a payload field: a session only reaches
# the phone while it has one. See the note on the jq below.
#
# A reading with no sessions at all still goes out. The phone has to be able to
# tell "nothing is remotely drivable" from "the laptop is off", and the only
# thing that distinguishes those is a fresh message that says zero.
#
# The topic lives outside this repo, which is public. No topic file, no
# publishing: this exits quietly rather than failing a graphical session.

topicFile="${CLAUDE_NTFY_TOPIC_FILE:-$HOME/.config/claude-status/ntfy-topic}"
server="${CLAUDE_NTFY_SERVER:-https://ntfy.sh}"

# Republished this often even when nothing has changed, for two reasons: ntfy
# drops cached messages after 12h, and a reading that keeps arriving is how the
# phone can tell a laptop that is off from one with nothing running.
keepaliveSeconds="${CLAUDE_NTFY_KEEPALIVE:-3600}"

if [ ! -r "$topicFile" ]; then
  echo "no topic at $topicFile; not publishing" >&2
  exit 0
fi

topic=$(tr -d '[:space:]' < "$topicFile")
if [ -z "$topic" ]; then
  echo "empty topic at $topicFile; not publishing" >&2
  exit 0
fi

lastPayload=""
lastSentAt=0

while IFS= read -r reading; do
  # Only sessions that still hold a bridge. On this surface a square's one
  # action is opening claude.ai/code/<bridge>, so a session without one is a
  # square that does nothing when tapped -- which is exactly what was left on
  # the phone after Remote Control was disconnected. The desktop keeps those
  # sessions, because there a click focuses the kitty tab and still works.
  #
  # The counts are recomputed from the filtered set rather than passed through,
  # or the readout would claim sessions the phone is not drawing.
  payload=$(jq -c '
    [ .sessions[] | select(.bridge != null) ] as $open
    | {
        ready: ([ $open[] | select(.status == "idle" or .status == "waiting") ] | length),
        busy: ([ $open[] | select(.status == "busy") ] | length),
        total: ($open | length),
        sessions: [ $open[] | { status, origin: (.origin // "local"), bridge } ],
      }
    | .state = (if .ready > 0 then "ready" elif .busy > 0 then "busy" else "none" end)
  ' <<<"$reading") || continue

  now=$(date +%s)
  if [ "$payload" = "$lastPayload" ] && [ $((now - lastSentAt)) -lt "$keepaliveSeconds" ]; then
    continue
  fi

  # Priority min: this is a feed for a widget to poll, not something to buzz a
  # phone about. Claude Code's own push notifications already do that part.
  if jq -c --argjson at "$now" '. + { at: $at }' <<<"$payload" \
    | curl -fsS --max-time 20 \
        -H "Priority: min" \
        -H "Title: claude-status" \
        -H "Content-Type: application/json" \
        --data-binary @- \
        "$server/$topic" >/dev/null
  then
    lastPayload=$payload
    lastSentAt=$now
  fi
done

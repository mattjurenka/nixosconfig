# Streams this account's plan usage, one JSON line per reading.
#
# The reading is the same one `/usage` shows inside Claude Code: it comes from
# api.anthropic.com's own OAuth usage endpoint, with the access token Claude
# Code already keeps in ~/.claude/.credentials.json. Nothing here estimates
# anything from transcripts -- the percentage is the account's, as the server
# counts it, including whatever the agent VMs and the phone spent.
#
# The two windows are independent limits: the session window (five hours) and
# the weekly one are counted separately and reset separately, so either can be
# the one that runs out. Both are reported, and the widget draws both.
#
# Claude Code refreshes that token in place, and this re-reads the file every
# time, so it follows along. It cannot refresh the token itself (that needs the
# OAuth flow), so an expired one simply yields no reading until Claude Code
# renews it, and the indicator keeps showing the last one it had.
#
# Unlike the session watcher this does poll: a rate limit window has no event
# to subscribe to. Once every two minutes is far finer than a five hour window
# needs, and is one small request.

CREDENTIALS="${CLAUDE_CREDENTIALS:-$HOME/.claude/.credentials.json}"
INTERVAL="${CLAUDE_USAGE_INTERVAL:-120}"

# One ISO timestamp out of the response, as a local clock time. The stamps
# carry fractional seconds, which date(1) will not parse, and the minute is
# finer than anything a tooltip needs anyway.
when() {
  local stamp
  stamp=$(jq -r "$2 // empty" <<<"$1" | sed 's/[.][0-9]*//')
  [ -n "$stamp" ] || return 0
  date -d "$stamp" +"$3" 2>/dev/null || true
}

reading() {
  local token response sessionResets weeklyResets

  [ -r "$CREDENTIALS" ] || return 1
  token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS" 2>/dev/null) || return 1
  [ -n "$token" ] || return 1

  response=$(curl -fsS --max-time 10 \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    https://api.anthropic.com/api/oauth/usage) || return 1

  sessionResets=$(when "$response" .five_hour.resets_at '%-I:%M %p')
  weeklyResets=$(when "$response" .seven_day.resets_at '%a %-I:%M %p')

  jq -ce --arg sessionResets "$sessionResets" --arg weeklyResets "$weeklyResets" '
    (.five_hour.utilization // null) as $session
    | (.seven_day.utilization // null) as $weekly
    | select($session != null or $weekly != null)
    | {
        percent: (if $session == null then null else ($session | round) end),
        resets: $sessionResets,
        weekly: (if $weekly == null then null else ($weekly | round) end),
        weeklyResets: $weeklyResets,
      }' <<<"$response"
}

while :; do
  if line=$(reading); then
    printf '%s\n' "$line"
  fi
  sleep "$INTERVAL"
done

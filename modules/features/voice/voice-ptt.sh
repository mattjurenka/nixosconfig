# Push to talk: one key, speak, hear the answer. No typing anywhere in it.
#
# Press Mod+V, say something, press Mod+V again. A third press while the answer
# is being worked out says so rather than starting a second conversation on top
# of the first.
#
# It is a toggle rather than one press with automatic stop-on-silence, and that
# was measured rather than chosen. This laptop's only working microphone is the
# ACP PDM array -- the analog ALC236 capture is switched off and has 0% gain,
# and the array exposes no mixer controls at all -- and it carries a -0.226 DC
# offset with a ~77Hz component, which puts its idle RMS at 0.26 with samples
# clipping. `highpass 80` below fixes the offset itself (mean goes to
# -0.000001, RMS to 0.0246), but even cleaned up a quiet room reads 0.0246 RMS
# against 0.0297 for speech: 20% apart, both spiking near full scale. No
# amplitude threshold separates those, so sox's `silence` effect kept either
# the whole 60s cap or nothing at all. A neural VAD would, but it cannot tell a
# *live* recording when to stop -- only trim one afterwards -- so the honest
# fix is the second press.
#
# Why this is a script on a compositor keybind rather than anything inside the
# editor: Zed's extensions are WASM with no audio or device API at all, and its
# one native extension type -- an MCP server -- can only ever be *called by the
# agent*, never by a person pressing a key. An agent-driven loop would have
# meant typing to start it, which is the one thing this is for.

set -u

STATE="${XDG_RUNTIME_DIR:-/tmp}/voice-ptt"
mkdir -p "$STATE"
LOCK="$STATE/lock"
REC_PID="$STATE/rec.pid"
WAV="$STATE/in.wav"

# The conversation id, so each press continues the last exchange instead of
# meeting a stranger. Kept under state rather than runtime so it survives a
# reboot; `voice-ptt reset` is how to start over.
CONV_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/voice"
SESSION="$CONV_DIR/session"
mkdir -p "$CONV_DIR"

say() { notify-send -a voice -u "${2:-low}" -h string:x-canonical-private-synchronous:voice "$1" "${3:-}"; }

if [ "${1:-}" = "reset" ]; then
  rm -f "$SESSION"
  say "Voice: new conversation" normal
  exit 0
fi

# Hold the lock for the whole exchange. A press that cannot get it is either a
# stop (recorder still running) or impatience (already thinking).
exec 9>"$LOCK"
if ! flock -n 9; then
  if [ -s "$REC_PID" ] && kill -0 "$(cat "$REC_PID")" 2>/dev/null; then
    kill "$(cat "$REC_PID")" 2>/dev/null || true
    exit 0
  fi
  say "Voice: still thinking" normal
  exit 0
fi

cleanup() { rm -f "$REC_PID"; }
trap cleanup EXIT

# ---------------------------------------------------------------- listen

say "Listening -- press again to send" normal
paplay "@beep@" >/dev/null 2>&1 || true

# `highpass 80` is not cosmetic: it removes the array's DC offset, which is
# what whisper would otherwise be reading speech out of. Left in, a 58-second
# recording of a quiet room with one question in it transcribed as
# "Phoenix (music)".
#
# `trim 0 @maxSeconds@` is the backstop for a key pressed by accident and
# forgotten about, so a stray press costs a bounded recording rather than one
# that runs until the session ends.
sox -t pulseaudio default -r 16000 -c 1 -b 16 "$WAV" \
  highpass 80 trim 0 @maxSeconds@ >/dev/null 2>&1 &
echo $! > "$REC_PID"
wait "$(cat "$REC_PID")" 2>/dev/null || true
cleanup

if [ ! -s "$WAV" ]; then
  say "Voice: nothing recorded" normal
  exit 0
fi

# ---------------------------------------------------------------- transcribe

say "Transcribing..." low
TEXT=$(whisper-cli -m "@model@" -f "$WAV" --no-timestamps --no-prints -t "@threads@" 2>/dev/null \
  | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '\n' ' ' \
  | sed 's/[[:space:]]\{2,\}/ /g; s/[[:space:]]*$//')

# Whisper emits bracketed markers for non-speech -- [BLANK_AUDIO], [ Silence ]
# -- and those are a miss, not a question.
case "$TEXT" in
  ""|"["*) say "Voice: didn't catch that" normal; exit 0 ;;
esac

say "You said" low "$TEXT"

# ---------------------------------------------------------------- ask Claude

# `claude -p` rather than the Messages API, because the subscription in
# ~/.claude is already paid for and already logged in; the API would be a
# second credential and metered tokens on top of it.
#
# Run from a scratch directory on purpose. A thread started here has no
# approved tool permissions, and in -p mode it cannot ask for any, so anything
# that would touch the filesystem is declined rather than silently allowed --
# a spoken sentence should not be able to edit a repo by accident.
cd "$CONV_DIR" || exit 1

RESUME=""
if [ -s "$SESSION" ]; then
  RESUME="--resume $(cat "$SESSION")"
fi

# shellcheck disable=SC2086
REPLY_JSON=$(claude -p --output-format json --model "@model_name@" $RESUME \
  --append-system-prompt "Your reply is being read aloud through a speaker, so write for the ear: at most two short sentences, plain spoken prose. No markdown, no lists, no code blocks, no URLs, no emoji. If the answer is genuinely long, say the one-line version and offer to go deeper." \
  -- "$TEXT" 2>/dev/null)

if [ -z "$REPLY_JSON" ]; then
  say "Voice: Claude didn't answer" critical
  exit 1
fi

ANSWER=$(printf '%s' "$REPLY_JSON" | jq -r '.result // empty')
NEW_SESSION=$(printf '%s' "$REPLY_JSON" | jq -r '.session_id // empty')
[ -n "$NEW_SESSION" ] && printf '%s' "$NEW_SESSION" > "$SESSION"

# A --resume against a session id Claude has forgotten fails rather than
# starting fresh, which would otherwise end the voice loop permanently until
# someone found the stale file.
if [ -z "$ANSWER" ]; then
  if [ -n "$RESUME" ]; then
    rm -f "$SESSION"
    say "Voice: conversation expired, press again" normal
  else
    say "Voice: no answer" critical
  fi
  exit 1
fi

# ---------------------------------------------------------------- speak

say "Claude" normal "$ANSWER"
printf '%s' "$ANSWER" | piper --model "@voice@" --output_file "$STATE/out.wav" >/dev/null 2>&1
[ -s "$STATE/out.wav" ] && paplay "$STATE/out.wav" >/dev/null 2>&1

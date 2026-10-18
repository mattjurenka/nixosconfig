# Re-ask the terminal for its size on every prompt until it answers, then stop.
#
# The shell is already running before anyone attaches -- `Restart = always`
# keeps one waiting on each console -- so shell startup is always too early to
# ask: there is no terminal on the far end yet, and `fit` fails. The first
# prompt drawn after an attach is the first moment the question can be
# answered, which puts the cost of a correctly-sized console at one keystroke.
#
# Deliberately does not latch on failure. If it did, the attempt made while
# detached would be the only one ever made, and the console would stay 80x24
# for the whole session.
#
# Resizing the host window mid-session still needs a manual `fit`, because
# there is no SIGWINCH to notice it with.
_fit_once() {
    if [ -z "${_FITTED:-}" ] && fit >/dev/null 2>&1; then
        _FITTED=1
    fi
}
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}_fit_once"

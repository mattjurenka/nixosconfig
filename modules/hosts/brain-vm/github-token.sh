# Print the GitHub PAT for one resource owner, and nothing else.
#
# The one place in the guest that knows where the tokens live, so `git` (through
# the credential helper) and `gh` (through the wrapper) resolve them the same
# way. Takes an owner -- `Stable-Finance`, `mattjurenka` -- because that is the
# unit a fine-grained PAT is scoped to: one token cannot cover both, and the
# variable name is derived from the owner rather than passed in.
#
# Two places are consulted, in this order, and the order is the whole design:
#
#   1. The process environment. `brain-console{,2,3}` load github.env as an
#      EnvironmentFile, so an attended session already has them.
#   2. The file itself, /var/lib/second-brain/github.env, mode 0600, owned by
#      claude -- which is the uid this runs as.
#
# Step 2 exists because step 1 silently fails for any session that did not
# inherit it, and the brain reported that as "I don't have access to GitHub"
# twice in one day (2026-10-13) about tokens that were readable by this uid the
# whole time. A process that can open the file has the credential; whether its
# parent happened to export it is not an interesting question.
#
# Step 2 is NOT taken when CLAUDE_INVOKED_BY is set. That is the attendance
# rule, and it is the only guard left now that github.py's `_guard_write()` is
# gone: an unattended run -- the heartbeat, the reflection agent, an SDK
# subagent -- reads PR and issue text that a third party wrote, and that text
# must not be one `gh` call away from a push-capable credential. Its own unit
# gives it whatever token it should have (github-read.env, read-only PATs); it
# does not get to reach past its environment into this file.
set -euo pipefail

owner=${1:-}
if [ -z "$owner" ]; then
    echo "usage: brain-github-token <owner>   # e.g. Stable-Finance, mattjurenka" >&2
    exit 2
fi

# Stable-Finance -> GH_TOKEN_STABLE_FINANCE, mattjurenka -> GH_TOKEN_MATTJURENKA.
var="GH_TOKEN_$(printf '%s' "$owner" | tr '[:lower:]-' '[:upper:]_')"
env_file=/var/lib/second-brain/github.env

# Indirect expansion, which is why this is bash and not sh.
token=${!var:-}
if [ -n "$token" ]; then
    printf '%s\n' "$token"
    exit 0
fi

if [ -n "${CLAUDE_INVOKED_BY:-}" ]; then
    echo "brain-github-token: $var is not in this unattended session's environment" \
         "(CLAUDE_INVOKED_BY=$CLAUDE_INVOKED_BY), and $env_file is deliberately not" \
         "read here -- an unattended run gets its credentials from its own unit." >&2
    exit 1
fi

if [ ! -r "$env_file" ]; then
    echo "brain-github-token: $var is unset and $env_file is not readable." \
         "Write the PATs there (mode 0600): $var=github_pat_..." >&2
    exit 1
fi

# One `var=value` line, quotes optional because systemd's EnvironmentFile accepts
# both and whoever wrote the file may have used either. Last match wins, which is
# also how systemd reads it.
token=$(sed -n "s/^[[:space:]]*$var=//p" "$env_file" | tail -n1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")
if [ -z "$token" ]; then
    echo "brain-github-token: $env_file has no $var line, so $owner is unreachable." \
         "A fine-grained PAT covers one owner; each needs its own." >&2
    exit 1
fi

printf '%s\n' "$token"

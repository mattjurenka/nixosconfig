# `gh`, with the right token already chosen.
#
# gh holds one token per host, and a fine-grained PAT covers one resource owner,
# so the two owners in scope (Stable-Finance and mattjurenka) cannot both be
# satisfied by `gh auth login`. The old answer was a Python wrapper that injected
# GH_TOKEN per call and exposed three functions; this is the same injection with
# nothing on top, so `gh pr create`, `gh pr list`, `gh run view` -- any gh
# command at all -- work as documented.
#
# The owner is resolved from the first of these that answers, because that is the
# order in which gh itself decides which repo a command is about:
#
#   1. `--repo OWNER/REPO` or `-R OWNER/REPO` on the command line.
#   2. the `origin` remote of the repository the shell is in.
#   3. DEFAULT_OWNER below.
#
# A token already in the environment wins over all of it: github.py sets GH_TOKEN
# explicitly for its own sweeps, and a wrapper that second-guessed that would
# pick a different token than the caller asked for.
set -euo pipefail

# Four of the five repos in scope are the org's, so this is the useful default for
# the commands that name no repo at all (`gh api user`, `gh auth status`).
DEFAULT_OWNER=Stable-Finance

real_gh=@realGh@

if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
    exec "$real_gh" "$@"
fi

owner=""

# 1. --repo / -R, in either `--repo x` or `--repo=x` form.
prev=""
for arg in "$@"; do
    case "$prev" in
        --repo|-R) owner=${arg%%/*}; break ;;
    esac
    case "$arg" in
        --repo=*) owner=${arg#--repo=}; owner=${owner%%/*}; break ;;
    esac
    prev=$arg
done

# 2. The checkout's own remote. `git remote get-url` is quiet and cheap outside a
# repository -- it just fails -- so this needs no is-a-repo test first.
if [ -z "$owner" ]; then
    url=$(git remote get-url origin 2>/dev/null || true)
    case "$url" in
        *github.com[:/]*)
            rest=${url#*github.com}
            rest=${rest#:}
            rest=${rest#/}
            owner=${rest%%/*}
            ;;
    esac
fi

[ -n "$owner" ] || owner=$DEFAULT_OWNER

# A missing token is not fatal here: gh's own "gh auth login" error is clearer
# about what the command needed than anything this can say, and brain-github-token
# has already explained on stderr why it could not produce one.
if token=$(@brainGithubToken@ "$owner"); then
    export GH_TOKEN=$token
    # gh prefers its own stored credentials over GH_TOKEN for some subcommands,
    # and GITHUB_TOKEN over both. Neither should be in play in this guest, but an
    # inherited one would silently send the wrong identity.
    unset GITHUB_TOKEN
fi

exec "$real_gh" "$@"

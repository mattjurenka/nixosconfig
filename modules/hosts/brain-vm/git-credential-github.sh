# git's credential helper for github.com, so `git clone`, `git fetch` and
# `git push` over HTTPS just work without anyone typing a token.
#
# This replaces what used to be a Python API: `github.py` held the PATs and
# exposed three write functions (comment on a PR, open a PR, comment on an
# issue), so anything outside that list -- a branch, a commit, a push -- read
# from the inside as "I don't have the ability", which is what the brain kept
# reporting. Handing git the credential instead means the ordinary commands are
# the interface, and the scope of what the brain may touch is the scope of the
# PAT rather than the shape of a wrapper.
#
# `useHttpPath = true` in /etc/gitconfig is what makes this work: without it git
# sends only `host=github.com` and there is no way to tell Stable-Finance's repos
# from Matt's, which need different tokens. With it, `path=Owner/repo.git`
# arrives and the owner is the first segment.
#
# Only `get` is implemented. `store` is a no-op on purpose -- the tokens live in
# one file that Matt wrote, and a helper that also writes them would give git a
# second, stale copy to prefer. `erase` likewise: there is nothing cached to
# erase.
set -euo pipefail

operation=${1:-}
[ "$operation" = "get" ] || exit 0

# git speaks key=value lines on stdin, terminated by a blank line or EOF.
protocol=""
host=""
path=""
while IFS= read -r line; do
    [ -z "$line" ] && break
    case "$line" in
        protocol=*) protocol=${line#protocol=} ;;
        host=*)     host=${line#host=} ;;
        path=*)     path=${line#path=} ;;
    esac
done

# Answer for github.com over https and nothing else. Declining is silent and
# costs nothing: git falls through to its next helper, or prompts.
[ "$protocol" = "https" ] || exit 0
[ "$host" = "github.com" ] || exit 0

# path is `Owner/repo.git`; the owner is what selects the token.
owner=${path%%/*}
[ -n "$owner" ] || exit 0

# Failure is reported on stderr and then declined rather than aborted, so git's
# own error ("Authentication failed") arrives with the reason above it instead of
# a helper traceback replacing it.
token=$(@brainGithubToken@ "$owner") || exit 0

# x-access-token is GitHub's documented username for token auth; any non-empty
# username works, and this one says what the password is.
echo "username=x-access-token"
echo "password=$token"

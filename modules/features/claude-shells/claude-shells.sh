# What Claude Code's backgrounded commands are printing, on this machine.
#
# A `run_in_background` Bash call is a shell the agent keeps for itself: it
# polls that shell with BashOutput and quotes back only what it decides to
# quote, and no editor in front of it is shown the shell at all. Zed is the
# case that matters here -- see modules/features/zed.nix -- because the ACP
# adapter publishes background tasks only over an extension Zed does not
# advertise, so the thread shows the "running in background" notice and then
# nothing, however much that shell is printing.
#
# The output is on disk, though, which is what this reads:
# $TMPDIR/claude-$UID/<project-slug>/<session-id>/tasks/<task-id>.output, one
# file per *Bash call*, appended live. Nothing below talks to an agent, a
# session or a socket -- files and /proc only, so it is safe to run beside a
# working swarm and it cannot type into anything.
#
# Usage:
#   claude-shells            # table of live shells, then follow all of them
#   claude-shells --list     # table only, no follow
#   claude-shells --here     # only shells whose agent is working under $PWD
#   claude-shells --all      # include shells that have already finished
#
# CLAUDE_SHELLS_BACKLOG     lines of existing output to show per shell (20)
# CLAUDE_SHELLS_INTERVAL    seconds between rescans for new shells (2)
# CLAUDE_SHELLS_MAX_AGE     how far back --all reaches, in seconds (604800)

follow=1
here=0
all=0
backlog=${CLAUDE_SHELLS_BACKLOG:-20}
interval=${CLAUDE_SHELLS_INTERVAL:-2}
max_age=${CLAUDE_SHELLS_MAX_AGE:-604800}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -l | --list) follow=0 ;;
    --here) here=1 ;;
    -a | --all) all=1 ;;
    -h | --help)
      sed -n '/^# Usage:/,/^# CLAUDE_SHELLS_MAX_AGE/p' "$0" | cut -c3-
      exit 0
      ;;
    *)
      echo "claude-shells: unknown argument $1" >&2
      exit 2
      ;;
  esac
  shift
done

# Where the CLI put the files. node's os.tmpdir() honours TMPDIR, so a session
# started with one set spooled somewhere else than a session started without --
# look in both rather than guessing which kind of session is running.
uid=$(id -u)
roots=("/tmp/claude-$uid")
if [ -n "${TMPDIR:-}" ] && [ "${TMPDIR%/}" != "/tmp" ]; then
  roots+=("${TMPDIR%/}/claude-$uid")
fi

if [ -t 1 ]; then
  dim=$'\033[2m'
  bold=$'\033[1m'
  green=$'\033[32m'
  off=$'\033[0m'
else
  dim=""
  bold=""
  green=""
  off=""
fi

now=0
held=""
shells=""
spool=$(mktemp -t claude-shells.XXXXXX)

# task id -> what the agent asked that shell to do, and the ids a transcript
# has already been searched for in vain. Both survive a rescan, which is the
# point: the transcripts are the expensive part of this, and they only need
# reading when a task id turns up that is not in the map yet.
declare -A command_of=()
declare -A missing=()

# Which shells follow mode has a `tail` on, consulted by the scan: a shell
# that has just finished has to survive one more scan so its last lines and its
# verdict can be printed, even though the filter below would now drop it.
declare -A followed=()

# How a shell ended, or empty while it is still running.
#
# This is the liveness test, and the one an fd check would have been: an open
# descriptor on a spool file outlives the shell, because it gets inherited. In
# brain-vm the Zed remote server was still holding two of them an hour after
# both commands had finished, which read as two live shells that were not
# there. The wrapper that runs each Bash call closes the file with a blank line
# and a bracketed verdict instead -- "[exited with code 0]", "[killed by
# signal SIGKILL]" -- and that survives whatever happens to the processes.
#
# Only the tail is read: a dev server's log can be megabytes.
exit_of() {
  tail -c 300 "$1" 2>/dev/null |
    sed -n 's/^\[exited with code \(.*\)\]$/exit \1/p; s/^\[killed by signal \(.*\)\]$/sig \1/p' |
    tail -n 1
}

# Every process holding a spool file open, and which of them is the shell.
# One `find` over /proc rather than a readlink per descriptor, because this
# runs on every rescan: a few hundred processes with a few dozen descriptors
# each measured 8.8s that way against 0.02s this way.
#
# `held` is every path somebody has open. Not a liveness test (see exit_of) --
# it only tells a shell whose session died, with no verdict in its file and
# nobody writing to it, from one that is genuinely still going.
#
# `shells` is path -> pid for the wrapper Claude Code started: it runs every
# Bash call through a snapshot of the login shell, so the wrapper is the holder
# whose argv names a file under shell-snapshots/. That is the pid worth
# printing because it is the pid of the *shell* -- the command under it may be
# a `sleep` that is replaced every second, and a holder outside the pair (the
# editor's inherited copy above) is not the shell at all.
read_processes() {
  local fds target pid
  fds=$(
    find /proc/[0-9]*/fd -maxdepth 1 -lname '*.output' -printf '%l\t%p\n' 2>/dev/null |
      sed 's|\t/proc/|\t|; s|/fd/[0-9]*$||' |
      sort -u
  )

  held=$(printf '%s\n' "$fds" | cut -f1 | sort -u)
  shells=""
  while IFS=$'\t' read -r target pid; do
    [ -n "$pid" ] || continue
    grep -qa shell-snapshots "/proc/$pid/cmdline" 2>/dev/null || continue
    shells+="$target	$pid"$'\n'
  done < <(printf '%s\n' "$fds")
}

# The session's transcript, which is the only place two things can be read: the
# working directory the agent was given (the spool directory's name is a slug
# with every separator flattened to a dash, so it cannot be turned back into a
# path), and which of its Bash calls were backgrounded.
#
# That second one is load-bearing. *Every* Bash call spools to a tasks/*.output
# file, foreground ones included -- this script's own call has one open while
# it runs -- so a file alone says nothing about whether a shell was left
# running. A backgrounded call is the one whose tool_result carries a
# `backgroundTaskId`, and nothing else distinguishes it on disk.
transcript_of() {
  printf '%s/.claude/projects/%s/%s.jsonl' "${HOME:-/root}" "$1" "$2"
}

cwd_of() {
  [ -r "$1" ] || return 0
  head -n 50 "$1" 2>/dev/null |
    jq -rc 'select(.cwd != null) | .cwd' 2>/dev/null |
    head -n 1
}

# Fills command_of for every backgrounded task in one transcript. The id lives
# in the tool_result's structured half, which carries the tool_use id, and the
# command and description are back in the tool_use that produced it -- always
# earlier in the file, so a single streaming pass can join them.
#
# Streaming per record rather than slurping the file, because the transcript of
# a running session is being appended to while this reads it: the last line can
# be half written, and a streaming jq has already printed every complete record
# by the time it trips over that one.
read_transcript() {
  local file=$1 task cmd
  [ -r "$file" ] || return 0
  while IFS=$'\t' read -r task cmd; do
    [ -n "$task" ] || continue
    command_of[$task]=$cmd
  done < <(
    jq -rc '
      if (.toolUseResult | type) == "object" and .toolUseResult.backgroundTaskId != null
      then ["task", (.message.content[0].tool_use_id // ""), .toolUseResult.backgroundTaskId]
      elif (.message.content | type) == "array"
      then
        ( .message.content[]
          | select(.type == "tool_use" and (.name == "Bash" or .name == "PowerShell"))
          | ["cmd", .id, ((.input.description // .input.command // "") | gsub("\\s+"; " "))] )
      else empty
      end
      | @tsv
    ' "$file" 2>/dev/null |
      awk -F'\t' '
        $1 == "cmd"  { cmd[$2] = $3 }
        $1 == "task" { print $3 "\t" cmd[$2] }
      '
  )
}

age_of() {
  if [ "$1" -lt 60 ]; then printf '%ds' "$1"
  elif [ "$1" -lt 3600 ]; then printf '%dm' "$(($1 / 60))"
  elif [ "$1" -lt 86400 ]; then printf '%dh' "$(($1 / 3600))"
  else printf '%dd' "$(($1 / 86400))"
  fi
}

# One line per background shell:
# "path<TAB>task<TAB>live<TAB>status<TAB>pid<TAB>mtime<TAB>age<TAB>size<TAB>cwd<TAB>command".
# The raw mtime travels beside the printable age because sorting on "4m" and
# "6h" as text puts them in the wrong order.
#
# Deliberately not a subshell: the caller redirects this into a file, so the
# two caches above outlive a rescan.
scan() {
  local root dir slug session transcript cwd file task verdict live status pid mtime
  now=$(date +%s)
  read_processes

  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    for dir in "$root"/*/*/tasks; do
      [ -d "$dir" ] || continue
      session=${dir%/tasks}
      slug=${session%/*}
      slug=${slug##*/}
      session=${session##*/}
      transcript=""
      cwd=""

      for file in "$dir"/*.output; do
        [ -f "$file" ] || continue
        task=${file##*/}
        task=${task%.output}

        mtime=$(stat -c %Y "$file" 2>/dev/null || echo "$now")
        verdict=$(exit_of "$file")
        if [ -n "$verdict" ]; then
          live=0
          status=$verdict
        elif printf '%s\n' "$held" | grep -qxF "$file"; then
          live=1
          status=live
        elif [ "$((now - mtime))" -lt 60 ]; then
          # No verdict, nobody holding it, and seconds old: a shell that has
          # just started. The wrapper opens the file before the first write,
          # so this is a race with the /proc walk rather than a state.
          live=1
          status=live
        else
          # No verdict and nobody writing: the session that owned this shell
          # died before the shell could be closed out. Worth its own word,
          # because the output is all there is and nothing will add to it.
          live=0
          status=stale
        fi

        # Everything the cheap tests can reject, rejected before a transcript
        # is opened: a finished shell nobody asked for, and anything older than
        # the window. A week of spool files across a dozen sessions is the
        # difference between this answering now and reading 200 MB of JSON.
        [ "$live" = 1 ] || [ "$all" = 1 ] || [ -n "${followed[$task]-}" ] || continue
        [ "$((now - mtime))" -le "$max_age" ] || continue

        if [ -z "${command_of[$task]-}" ] && [ -z "${missing[$task]-}" ]; then
          transcript=${transcript:-$(transcript_of "$slug" "$session")}
          read_transcript "$transcript"
          # Still unknown: a foreground Bash call's spool file, or a session
          # whose transcript has been pruned. Either way there is nothing to
          # show, and no reason to read that file again for this id.
          [ -n "${command_of[$task]-}" ] || missing[$task]=1
        fi
        [ -n "${command_of[$task]-}" ] || continue

        if [ -z "$cwd" ]; then
          transcript=${transcript:-$(transcript_of "$slug" "$session")}
          cwd=$(cwd_of "$transcript")
          cwd=${cwd:-slug:$slug}
        fi
        if [ "$here" = 1 ] && [ "${cwd#"$PWD"}" = "$cwd" ]; then continue; fi

        pid=$(printf '%s\n' "$shells" |
          awk -F'\t' -v f="$file" '$1 == f { print $2; exit }')

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$file" "$task" "$live" "$status" "${pid:--}" "$mtime" \
          "$(age_of "$((now - mtime))")" \
          "$(numfmt --to=iec "$(stat -c %s "$file" 2>/dev/null || echo 0)")" \
          "$cwd" "${command_of[$task]}"
      done
    done
  done
}

table() {
  local file task live status pid mtime age size cwd cmd colour room
  # The command is the only column that can be any length, so it is the one
  # that gets clipped -- and clipping the field rather than the line, because
  # the line carries the colour escapes that make live stand out from done.
  room=$(($( { stty size 2>/dev/null || echo "24 120"; } |
    awk '{ print ($2 > 60 ? $2 : 120) }') - 56))
  printf '%s%-8s %-10s %-7s %4s %5s  %-16s %s%s\n' \
    "$bold" "STATUS" "TASK" "PID" "AGE" "SIZE" "PROJECT" "COMMAND" "$off"
  sort -t$'\t' -k3,3r -k6,6nr |
    while IFS=$'\t' read -r file task live status pid mtime age size cwd cmd; do
      [ -n "$task" ] || continue
      if [ "$live" = 1 ]; then colour=$green; else colour=$dim; fi
      printf '%s%-8s %-10s %-7s %4s %5s  %-16s %s%s\n' \
        "$colour" "$status" "$task" "$pid" "$age" "$size" \
        "${cwd##*/}" "${cmd:0:$room}" "$off"
    done
}

cleanup() {
  local pid
  for pid in "${tails[@]-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  rm -f "$spool"
}
tails=()
trap 'cleanup; exit 0' INT TERM
trap cleanup EXIT

scan > "$spool"

if [ "$follow" = 0 ]; then
  if [ ! -s "$spool" ]; then
    if [ "$here" = 1 ]; then
      echo "claude-shells: no background shells under $PWD"
    else
      echo "claude-shells: no background shells on this machine"
    fi
    exit 0
  fi
  table < "$spool"
  exit 0
fi

# Follow mode: one `tail -F` per live shell, its lines prefixed with the task id
# so a pane carrying three dev servers can still be read, and a rescan every
# couple of seconds to pick up whatever an agent started in the meantime.
table < "$spool"
[ -s "$spool" ] ||
  printf '%sclaude-shells: nothing in the background yet -- watching%s\n' "$dim" "$off"
echo

# The shells listed in the table above do not need announcing again; everything
# discovered by a later rescan does.
announce=0
while :; do
  while IFS=$'\t' read -r file task live status pid mtime age size cwd cmd; do
    [ -n "$task" ] || continue
    if [ "$live" = 1 ] && [ -z "${followed[$task]-}" ]; then
      followed[$task]=1
      [ "$announce" = 0 ] ||
        printf '%s>> %s  %s  %s%s\n' "$bold" "$task" "${cwd##*/}" "$cmd" "$off"
      tail -n "$backlog" -F -- "$file" 2>/dev/null |
        sed -u "s/^/${dim}${task}${off} /" &
      tails+=("$!")
    elif [ "$live" = 0 ] && [ "${followed[$task]-}" = 1 ]; then
      followed[$task]=2
      printf '%s<< %s %s%s\n' "$dim" "$task" "$status" "$off"
    fi
  done < "$spool"
  announce=1
  sleep "$interval"
  scan > "$spool"
done

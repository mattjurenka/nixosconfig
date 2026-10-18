# Brings one Claude Code session to the front, given its JSON record from
# claude-ready-watch: focus the window it is already running in, or -- when it
# has none, which is the normal state of a background agent -- open a terminal
# attached to it.
#
# A Zed agent thread is the other shape a session comes in, and it is handled
# on its own below: it belongs to the editor rather than to a terminal, so
# there is no tab to find and nothing to attach to.
#
# For everything else, finding the window means walking up from the session's
# own process until a pid turns up that niri knows as a window, since the
# terminal is somewhere above claude in the process tree. The same walk finds
# the kitty *tab*, which niri cannot see into: kitty reports the processes
# running in each of its windows over its control socket.

session="${1:-}"
if [ -z "$session" ]; then
  echo "usage: claude-session-focus '<session json>'" >&2
  exit 2
fi

# One field per line, read with mapfile: a tab-separated read would be wrong
# here, because tab is IFS whitespace and an empty field -- which `id` is for
# every session that is not a background agent -- would collapse and shift
# every later value one place left.
mapfile -t fields < <(
  jq -r '
    (.pid // ""),
    (.id // ""),
    (.sessionId // ""),
    (.cwd // ""),
    (.configDir // ""),
    ((.name // "claude") | gsub("[\\n\\r\\t]"; " ")),
    (.origin // "local"),
    (.agent // "cli")
  ' <<<"$session"
)

pid="${fields[0]:-}"
jobId="${fields[1]:-}"
sessionId="${fields[2]:-}"
cwd="${fields[3]:-}"
configDir="${fields[4]:-}"
name="${fields[5]:-claude}"
origin="${fields[6]:-local}"

# "zed" for a thread in the editor's agent panel, "cli" for a session in a
# terminal. A reading published by a machine running an older watcher carries
# no agent at all, and "cli" is the right thing to assume there: it is what
# every session was before the editor grew a panel.
agent="${fields[7]:-cli}"

# A Zed agent thread runs under the editor, not under a terminal: Zed starts
# claude-agent-acp, the acp process execs claude, and nothing in that chain has
# a tab. So the window to focus is Zed's own, found by app id -- and it is
# *this* machine's Zed even for a thread in an agent VM, because the editor
# drives a remote project over SSH while the process the reading came from
# lives in the guest.
#
# Zed titles a window after the project it has open, which is the one thing
# that tells two of its windows apart, and the thread's cwd is a path inside
# that project -- so the last component of the cwd is what to look for.
#
# What is deliberately *not* here is a fall-through to whichever Zed window
# happens to exist. A thread can be open in the editor with no window of its
# own: Zed keeps a project loaded after its window closes, which is the normal
# state of a thread in an agent VM, and focusing the window of some other
# project only looks like it worked. So an unmatched project is asked for by
# name below instead.
if [ "$agent" = "zed" ]; then
  project=""
  if [ -n "$cwd" ]; then
    project=$(basename "$cwd")
  fi

  zed_window() {
    niri msg --json windows 2>/dev/null | jq -r --arg project "$project" '
      [ .[] | select(.app_id == "dev.zed.Zed") ] as $zed
      | [ $zed[] | select((.title // "") == $project) ]
        + [ $zed[] | select($project != "" and ((.title // "") | contains($project))) ]
        | first | .id // empty
    '
  }

  zedWindow=$(zed_window) || zedWindow=""
  if [ -n "$zedWindow" ]; then
    niri msg action focus-window --id "$zedWindow"
    exit 0
  fi

  # Nothing is showing that project, so ask the editor for it. `zeditor` takes
  # an `ssh://user@host/path` URL as well as a local path -- undocumented in
  # its own `--help`, but it is how Zed names a remote project, and it reuses
  # the connection a thread in that guest is already running over rather than
  # starting a second one. That is the difference between landing in the
  # thread and sitting on "Starting proxy".
  #
  # -n because the project has no window: without it Zed opens the project in
  # whichever window is current, which means a click on a thread in the guest
  # replaces the window Matt had his own checkout open in.
  target=""
  if [ "$origin" = "local" ]; then
    [ -n "$cwd" ] && [ -d "$cwd" ] && target="$cwd"
  else
    # The guest logins, from the same address plan zed.nix builds its
    # ssh_connections from, so a thread cannot be pointed at an address the
    # editor does not use. An origin that is not in the map -- a machine this
    # host does not run -- leaves this empty and falls through.
    target=$(jq -r --arg origin "$origin" --arg cwd "$cwd" '
      (.[$origin] // "") as $base
      | if $base == "" or $cwd == "" then empty else $base + $cwd end
    ' <<<'@vmProjects@') || target=""
  fi

  if [ -n "$target" ]; then
    # One opener per project at a time. Opening a window is slow enough to
    # double-click through -- and every window Zed opens starts a thread of
    # its own, so a burst of clicks on the same square cost a burst of windows
    # and a 240 MB claude process behind each new empty tab. The lock makes the
    # second click wait for the first and then find the window below instead.
    exec 9>"${XDG_RUNTIME_DIR:-/tmp}/claude-zed-open.$(printf '%s' "$project" | tr -c '[:alnum:]' _).lock"
    flock 9

    zedWindow=$(zed_window) || zedWindow=""
    if [ -n "$zedWindow" ]; then
      niri msg action focus-window --id "$zedWindow"
      exit 0
    fi

    claude-zed-open -n "$target" || true

    # Zed opens the window but cannot raise it: gpui logs "activate is not
    # implemented on Linux, ignoring the call" and the window arrives behind
    # whatever was in front, which on 2026-10-17 was a game. So the focus is
    # done here, once the window exists -- waited for rather than slept on,
    # since a project on a connection that is already up appears in about a
    # second and a cold one takes longer.
    for _ in $(seq 20); do
      sleep 0.5
      zedWindow=$(zed_window) || zedWindow=""
      if [ -n "$zedWindow" ]; then
        niri msg action focus-window --id "$zedWindow"
        exit 0
      fi
    done

    exit 0
  fi

  # No project to name: get the editor up on whatever it had open last, which
  # at least puts the threads sidebar in front of him.
  exec claude-zed-open
fi

# A pid and every pid above it, stopping before init.
ancestry() {
  local current="$1" stat
  while [ -n "$current" ] && [ "$current" != "0" ] && [ "$current" != "1" ]; do
    printf '%s\n' "$current"
    stat=$(cat "/proc/$current/stat" 2>/dev/null) || break
    # The comm field can hold spaces and brackets, so count fields from after
    # the closing bracket: state, then ppid.
    current=$(printf '%s' "$stat" | sed 's/^.*) //' | cut -d' ' -f2)
  done
}

# Which processes here lead to the window this session is being watched in.
#
# A session on this machine is below its own terminal, so its own pid is the
# way up -- plus any terminal already attached to the job, since `claude
# attach` runs as its own process and the agent's pid is not under it.
#
# A session in an agent VM has no process here at all. What there is is a
# console client, one per terminal attached to that guest, and the guest's pid
# means nothing on this side. See claude-ready-watch for how its reading gets
# out of the guest in the first place.
candidates=()
if [ "$origin" = "local" ]; then
  if [ -n "$pid" ]; then
    candidates+=("$pid")
  fi
  if [ -n "$jobId" ]; then
    while read -r attached; do
      candidates+=("$attached")
    done < <(pgrep -f "claude attach $jobId" || true)
  fi
else
  # Matched on the console socket rather than on `<vm>-console`, because that
  # wrapper execs socat and its own name is gone by the time it is attached.
  # The socket path is modules/features/agent-vm/plan.nix's consoleSocketFor.
  while read -r console; do
    candidates+=("$console")
  done < <(pgrep -f "/$origin/console" || true)
fi

related=()
for candidate in "${candidates[@]}"; do
  while read -r ancestor; do
    related+=("$ancestor")
  done < <(ancestry "$candidate")
done

if [ "${#related[@]}" -eq 0 ]; then
  relatedJson='[]'
else
  relatedJson=$(printf '%s\n' "${related[@]}" | jq -cs 'map(tonumber)')
fi

# The kitty tab first, so that niri's focus lands last and wins.
for socket in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/kitty.sock-*; do
  [ -S "$socket" ] || continue

  listing=$(kitty @ --to "unix:$socket" ls 2>/dev/null) || continue
  kittyWindow=$(jq -r --argjson related "$relatedJson" '
    [ .[] | .tabs[] | .windows[]
      | select([.pid] + [.foreground_processes[].pid] | any(. as $p | $related | index($p)))
      | .id ]
    | first // empty
  ' <<<"$listing") || continue

  if [ -n "$kittyWindow" ]; then
    kitty @ --to "unix:$socket" focus-window --match "id:$kittyWindow" >/dev/null 2>&1 || true
    break
  fi
done

window=$(niri msg --json windows 2>/dev/null | jq -r --argjson related "$relatedJson" '
  [ .[] | select(.pid != null and (.pid as $p | $related | index($p))) | .id ] | first // empty
') || window=""

if [ -n "$window" ]; then
  niri msg action focus-window --id "$window"
  exit 0
fi

# No window anywhere, so make one. A background agent is attached by its short
# id; anything else is resumed by session id, which is also the honest answer
# for a session whose terminal has gone away.
#
# The title is set here because `claude attach` does not set one, and the
# window would otherwise be called "env" after the command that carries the
# config dir into it.
terminal=(kitty --title "$name")

# A guest's session is reached through a console into that guest, and the
# console command picks a free console itself. Nothing below applies: cwd,
# config dir and job id all name things inside the VM.
if [ "$origin" != "local" ]; then
  exec "${terminal[@]}" "$origin-console"
fi

if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  terminal+=(--directory "$cwd")
fi

if [ -n "$jobId" ]; then
  exec "${terminal[@]}" env CLAUDE_CONFIG_DIR="$configDir" claude attach "$jobId"
elif [ -n "$sessionId" ]; then
  exec "${terminal[@]}" env CLAUDE_CONFIG_DIR="$configDir" claude --resume "$sessionId"
fi

exit 1

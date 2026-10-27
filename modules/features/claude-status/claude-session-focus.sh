# Brings one Claude Code session to the front, given its JSON record from
# claude-ready-watch: focus the window it is already running in, or -- when it
# has none, which is the normal state of a background agent -- open a terminal
# attached to it.
#
# A Claude session in corkboard is the other shape a session comes in, and it
# is handled on its own below: it is a terminal inside corkboard's Neovim, so
# there is no kitty tab to find and nothing to attach to.
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
    (.agent // "cli"),
    (.corkboard.nvim // ""),
    (.corkboard.buf // "" | tostring),
    (.corkboard.port // "")
  ' <<<"$session"
)

pid="${fields[0]:-}"
jobId="${fields[1]:-}"
sessionId="${fields[2]:-}"
cwd="${fields[3]:-}"
configDir="${fields[4]:-}"
name="${fields[5]:-claude}"
origin="${fields[6]:-local}"

# "corkboard" for a Claude session in corkboard, "cli" for one in a terminal.
# A reading published by a machine running an older watcher carries no agent
# at all, and "cli" is the right thing to assume there.
agent="${fields[7]:-cli}"
cbNvim="${fields[8]:-}"
cbBuf="${fields[9]:-}"
cbPort="${fields[10]:-}"

# A Claude session in corkboard is a terminal in corkboard's Neovim, shown in
# corkboard's own window, so there is no kitty tab to find. What there is
# instead is that Neovim's own server socket, read out of the session's
# environment by claude-ready-watch along with the terminal's buffer: asked
# over it, Neovim brings the session's terminal to the front (a tab of its
# own, or a window in one) and says which project it has open, and the app
# window titled after that project is the one to raise. The page titles
# itself "<project> — corkboard", or "<project> @ <host> — corkboard" for a
# project on another machine.
#
# Which app it is comes from the bridge's port: the installed corkboard and
# the dev one are separate apps, each with its own app_id (corkboard.nix),
# and the same project can be open in both.
#
# A session in an agent VM has its Neovim in the guest, out of reach of the
# socket, so for one of those the window is all there is to raise.
if [ "$agent" = "corkboard" ]; then
  appId=$(jq -r --arg port "$cbPort" '.[$port] // empty' <<<'@corkboardApps@') || appId=""

  suffix=""
  if [ "$origin" = "local" ] && [ -S "$cbNvim" ]; then
    # Bounded, so a Neovim that has stopped answering cannot hang the click.
    project=$(timeout 2 nvim --server "$cbNvim" --remote-expr 'fnamemodify(getcwd(-1, -1), ":t")' 2>/dev/null) || project=""
    if [ -n "$cbBuf" ]; then
      timeout 2 nvim --server "$cbNvim" \
        --remote-expr "luaeval('require(\"corkboard.picker\").focus_terminal(_A)', $cbBuf)" >/dev/null 2>&1 || true
    fi
    [ -n "$project" ] && suffix="$project — corkboard"
  elif [ "$origin" != "local" ]; then
    suffix=" @ $origin — corkboard"
  fi

  window=$(niri msg --json windows 2>/dev/null | jq -r --arg app "$appId" --arg suffix "$suffix" '
    [ .[] | select((.app_id // "") | test("^corkboard(-|$)")) ] as $corkboard
    | [ $corkboard[] | select($app == "" or .app_id == $app) ] as $mine
    | [ $mine[] | select($suffix != "" and ((.title // "") | contains($suffix))) ]
      + [ $corkboard[] | select($suffix != "" and ((.title // "") | contains($suffix))) ]
      | first | .id // empty
  ') || window=""

  if [ -n "$window" ]; then
    niri msg action focus-window --id "$window"
  fi
  exit 0
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

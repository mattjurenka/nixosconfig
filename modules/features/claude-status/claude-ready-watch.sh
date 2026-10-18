# Streams the state of the Claude Code work worth a square: one JSON line,
# re-emitted whenever it changes. A square is a project with threads in it --
# see the grouping at the end of local_sessions for why it is not a thread.
#
# Which ones those are is the Zed-first rule in local_sessions -- a thread in
# the editor agent panel that has been talked to -- and CLAUDE_READY_AGENTS is
# the knob back to every session the registry holds. The reading below is
# otherwise of everything, so the filter is the only place to look when a
# session that exists is not drawn.
#
# The source is the session registry that `claude agents --json` prints. Every
# session in it holds a messaging socket, which is what lets another agent
# drive it; sessions that opt out of the registry (`-p`,
# --no-session-persistence) never appear, which is what we want, since nothing
# is ever waiting on us there.
#
# Being in the registry is NOT the same as being remote-controllable, which an
# earlier version of this comment claimed. Remote Control adds a
# `bridgeSessionId` to a session's registry file while it is connected and
# takes it away again on disconnect; the session itself stays registered either
# way. So `bridge` below is present only while the session can be driven from
# claude.ai, and it is the ntfy publisher -- not this watcher -- that filters on
# it, because a square is still worth drawing on the desktop when the only way
# to reach the session is the keyboard in front of it.
#
# Claude Code keeps one registry per config dir and this user switches
# CLAUDE_CONFIG_DIR per repo (see the direnv note in matthew-home.nix), so
# every config dir is read and the results merged.
#
# A registry only ever covers its own machine: Remote Control is what lets a
# session elsewhere be driven, but nothing local can enumerate the account's
# other machines. So every machine runs this for itself, and the ones that are
# agent VMs publish their reading back through their outbox share (with
# CLAUDE_READY_OUT), which the host merges in below.

# Which machine this reading is of, carried on every session so a click knows
# whether to look for a window or for a console into a guest.
origin="${CLAUDE_READY_ORIGIN:-local}"

# Where to put each reading. Empty means stdout, which is what a shell widget
# subscribes to; a path makes this a publisher for whoever reads that file.
destination="${CLAUDE_READY_OUT:-}"

# Whose sessions this reading is of.
#
# "zed" is the default because the work moved into the editor's agent panel:
# the row of squares should read like Zed's own list of threads, and a session
# someone started in a terminal -- including the console session the agent VM
# runs its own admin work in -- is not a thread in that list. "all" is the knob
# back to every session on the machine, which is what this reported before.
#
# A thread also has to have been talked to; see conversations() below.
agentFilter="${CLAUDE_READY_AGENTS:-zed}"

# Readings published by other machines. A glob, not a list, so a new agent VM
# is picked up by existing it rather than by configuring it here.
remoteGlob="${CLAUDE_READY_REMOTE-@remoteGlob@}"

# A publisher rewrites its file at least once a minute, so anything older than
# this is a machine that is off, or a publisher that died.
remoteStaleSeconds=180

config_dirs() {
  printf '%s\n' "$HOME/.claude"
  local dir
  for dir in "$HOME"/.claude-configs/*/; do
    [ -d "$dir" ] && printf '%s\n' "${dir%/}"
  done
}

session_dirs() {
  local dir
  while read -r dir; do
    [ -d "$dir/sessions" ] && printf '%s\n' "$dir/sessions"
  done < <(config_dirs)
}

# The union of every registry, as one JSON array. A config dir whose registry
# cannot be read contributes nothing, so a host without Claude Code installed
# simply reports no sessions.
agents() {
  local dir out registry all='[]'
  while read -r dir; do
    # Run from / because `claude agents` only lists sessions under the cwd.
    out=$(cd / && CLAUDE_CONFIG_DIR="$dir" claude agents --json 2>/dev/null) || out=""

    # `claude agents` prints neither the remote-control id nor what started
    # the session, and the registry it reads carries both, so both are read
    # straight out of it and joined on pid.
    #
    # bridgeSessionId is the `session_...` that claude.ai/code/<id> resolves
    # to, which is what lets a square on the phone open the session it stands
    # for. entrypoint is how the session was started: "cli" for one someone
    # typed `claude` to get, "sdk-ts" for one the TypeScript Agent SDK drives
    # -- which is what a Zed agent thread is, and what acp_driven below asks
    # about.
    registry=$(jq -cs '
      map(select(.pid) | {
        key: (.pid | tostring),
        value: { bridge: .bridgeSessionId, entrypoint: .entrypoint },
      })
      | from_entries' "$dir"/sessions/*.json 2>/dev/null) || registry=""
    [ -n "$registry" ] || registry='{}'

    case "$out" in
      # Tagged with the registry it came from, because talking to a session
      # again means pointing claude back at the same config dir.
      '['*)
        all=$(jq -cn --argjson a "$all" --argjson b "$out" --arg dir "$dir" \
          --argjson registry "$registry" \
          '$a + ($b | map(. + { configDir: $dir } + ($registry[(.pid | tostring)] // {})))') || all='[]'
        ;;
    esac
  done < <(config_dirs)
  printf '%s\n' "$all"
}

# Whether a session is a Zed agent thread rather than one someone started in a
# terminal. That is the difference between a click that belongs in the editor
# and one that belongs in a kitty tab, so the reading has to carry it.
#
# `entrypoint` says the Agent SDK is driving the session but not what is
# driving the SDK, and it cannot be the whole answer on its own: the agent VM's
# heartbeat is an SDK session too. What makes it Zed is the process above it --
# the editor starts claude-agent-acp itself (see zed.nix) and the acp process
# execs claude, so it sits directly over the session. Walked rather than read
# one level up, since nothing promises that stays true.
#
# This is a question about processes, which is why it is answered here and not
# in claude-session-focus: a thread in an agent VM is driven by Zed on the host
# while its process lives in the guest, and the guest's own copy of this
# watcher is the only thing that can see the acp process above it.
acp_driven() {
  local pid=$1 depth=0 cmdline stat
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ] && [ "$depth" -lt 6 ]; do
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
    case "$cmdline" in
      *claude-agent-acp*) return 0 ;;
    esac

    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    # The comm field can hold spaces and brackets, so count fields from after
    # the closing bracket: state, then ppid.
    pid=$(printf '%s' "$stat" | sed 's/^.*) //' | cut -d' ' -f2)
    depth=$((depth + 1))
  done

  return 1
}

# Those sessions as one pid -> "zed" object, which is what the jq in
# local_sessions joins a session against. Only the SDK-driven ones are probed,
# so an ordinary terminal session costs nothing here.
session_agents() {
  local pid
  while read -r pid; do
    [ -n "$pid" ] || continue
    acp_driven "$pid" && jq -cn --arg k "$pid" '{ ($k): "zed" }'
  done < <(jq -r '.[] | select(.entrypoint == "sdk-ts") | (.pid // "") | tostring' <<<"$1") \
    | jq -cs 'add // {}'
}

# The topic Claude Code gave a session: the title it shows in the resume list,
# which it writes into the transcript as an `ai-title` line and rewrites
# whenever its reading of the conversation moves on. The session registry does
# not carry it at all, so it is read out of the transcript -- backwards,
# because the newest title is the one that counts and everything before it is
# the conversation.
#
# The transcript lives under the same config dir as the registry, in a
# directory named after the cwd. Globbing on the session id rather than
# slugifying that cwd ourselves keeps this out of the business of guessing how
# the name is spelled; the id is a uuid, so it can only match one file.
session_topic() {
  local dir=$1 id=$2 file title
  [ -n "$id" ] || return 0

  for file in "$dir"/projects/*/"$id".jsonl; do
    [ -f "$file" ] || continue
    # `|| :` rather than clearing the title on a non-zero status: grep stops at
    # the first match, which hands tac a SIGPIPE, which pipefail reports as a
    # failed pipeline even though the title it printed is exactly the one
    # wanted. An actual miss leaves the title empty on its own.
    title=$(tac "$file" | grep -m1 '"type":"ai-title"' | jq -r '.aiTitle // empty') || :
    if [ -n "$title" ]; then
      printf '%s\n' "$title"
      return 0
    fi
  done
}

# Which sessions have anything to go back to, as one sessionId -> true object.
#
# Zed starts an agent session the moment a thread tab is opened, before a word
# has been said in it, and that session registers exactly like any other: idle,
# untitled, and standing for a blank tab. The transcript is what tells the two
# apart -- Claude Code writes the file on the first message rather than at
# startup -- so a Zed thread with no transcript is a tab, not a conversation,
# and the row is better off without a square for it.
#
# The same glob as session_topic, for the same reason: the session id is a
# uuid, so it can only match the one file, whatever the directory it ended up
# named after.
conversations() {
  local dir id file
  while IFS=$'\t' read -r dir id; do
    [ -n "$id" ] || continue
    for file in "$dir"/projects/*/"$id".jsonl; do
      [ -s "$file" ] || continue
      jq -cn --arg k "$id" '{ ($k): true }'
      break
    done
  done < <(jq -r '.[] | [ .configDir, (.sessionId // "") ] | @tsv' <<<"$1") \
    | jq -cs 'add // {}'
}

# Those topics as one sessionId -> topic object, which is what the jq in
# local_sessions can join a session against. Looked up per session rather than
# by scanning the transcript directory, so the cost follows the sessions that
# exist and not the conversations that ever happened.
session_topics() {
  local dir id topic
  while IFS=$'\t' read -r dir id; do
    topic=$(session_topic "$dir" "$id") || topic=""
    [ -n "$topic" ] || continue
    jq -cn --arg k "$id" --arg v "$topic" '{ ($k): $v }'
  done < <(jq -r '.[] | [ .configDir, (.sessionId // "") ] | @tsv' <<<"$1") \
    | jq -cs 'add // {}'
}

# This machine's sessions, as the session records the indicator works in.
#
# idle and waiting both mean the session has handed control back to you; busy
# means it is still working. A session with no status yet counts as busy, so
# the indicator never claims attention it has not earned. Everything after
# status is what it takes to reach the session again: which program is driving
# it, its process, the short id a background agent is attached by, the
# remote-control id a phone opens it with, and where to resume it from
# otherwise.
local_sessions() {
  local all topics agentKinds said
  all=$(agents) || all='[]'
  topics=$(session_topics "$all") || topics='{}'
  [ -n "$topics" ] || topics='{}'
  agentKinds=$(session_agents "$all") || agentKinds='{}'
  [ -n "$agentKinds" ] || agentKinds='{}'
  said=$(conversations "$all") || said='{}'
  [ -n "$said" ] || said='{}'

  jq -c --arg origin "$origin" --arg filter "$agentFilter" --argjson topics "$topics" \
    --argjson agents "$agentKinds" --argjson said "$said" '
    def st: (.status // "busy");

    # Zed-first: a square stands for a thread in the editor that has been
    # talked to. Everything else -- a session in a terminal, a thread tab with
    # nothing said in it yet -- is real but is not what the row is for. A
    # reading published by a machine running an older watcher carries neither
    # field, and falls out here until that machine is rebuilt.
    def keep:
      $filter == "all" or (.agent == "zed" and (.conversation == true));

    # What gets written across a square. Two characters is what a square has
    # room for, and they are there to tell two squares apart rather than to be
    # read as a word: letters and digits of the topic only, so a title opening
    # with "I/O" reads IO instead of losing half of itself to the slash.
    #
    # A session Claude Code has not titled yet -- it writes the first title a
    # little way into the conversation -- falls back to the suffix of the name
    # derived from its cwd. That suffix is the one part of a derived name that
    # differs between two sessions in the same checkout, which is exactly the
    # pair a label is there to separate.
    # Two characters of a project name, which is what a square stands for: the
    # first two letters, since a project name is a word. The chip below takes
    # the *last* dash-separated segment instead, because a derived session name
    # ("nixosconfig-7b") carries its distinguishing part at the end -- which is
    # the wrong end of "second-brain".
    def projectChip($name):
      (($name // "") | ascii_upcase | gsub("[^A-Z0-9]"; ""))[0:2];

    def chip($topic; $name):
      (($topic // "") | ascii_upcase | gsub("[^A-Z0-9]"; "")) as $t
      | if ($t | length) > 0 then
          $t[0:2]
        else
          ((($name // "") | split("-") | last // "") | ascii_upcase)[0:2]
        end;

    [ .[]
      | (.sessionId // "") as $sid
      | (.name // (.cwd | split("/") | last)) as $name
      | {
        name: $name,
        topic: $topics[$sid],
        label: chip($topics[$sid]; $name),
        status: st,
        agent: ($agents[(.pid | tostring)] // "cli"),
        conversation: ($said[$sid] // false),
        startedAt: .startedAt,
        kind: .kind,
        origin: $origin,
        pid: .pid,
        id: .id,
        sessionId: .sessionId,
        bridge: .bridge,
        cwd: .cwd,
        configDir: .configDir,
      } ]

    # One square per thread, not per process.
    #
    # A thread can be running in more than one process at once: opening its
    # project in another window has Zed start a second agent session for the
    # thread it restores there, and the first one goes on running with no
    # window in front of it. Both register, both are live, and both carry the
    # same session id -- which is the thread -- so the row grew a second
    # square for a conversation that had not gained anything.
    #
    # The newest process is the one kept, since it is the one the editor just
    # attached to a window; the status is the busiest of them, because a
    # thread with work running in any of its processes is working.
    | group_by(.sessionId // ("pid:" + (.pid | tostring)))
    | map(
        (any(.[]; .status == "busy")) as $busy
        | (sort_by(.startedAt // 0) | last) as $live
        | $live + { status: (if $busy then "busy" else $live.status end) }
      )
    | map(select(keep))
  ' <<<"$all"
}

remote_dirs() {
  local file
  for file in $remoteGlob; do
    [ -f "$file" ] && printf '%s\n' "$(dirname "$file")"
  done | sort -u
}

# Sessions other machines have published, dropping any reading old enough to be
# a machine that is no longer running.
remote_sessions() {
  local file age now
  now=$(date +%s)

  for file in $remoteGlob; do
    [ -f "$file" ] || continue
    age=$(( now - $(stat -c %Y "$file" 2>/dev/null || echo 0) ))
    [ "$age" -lt "$remoteStaleSeconds" ] || continue
    jq -c '.sessions // []' "$file" 2>/dev/null || true
  done
}

snapshot() {
  local here elsewhere
  here=$(local_sessions) || here='[]'
  elsewhere=$(remote_sessions | jq -cs 'add // []') || elsewhere='[]'

  jq -cn --argjson here "$here" --argjson elsewhere "$elsewhere" --arg filter "$agentFilter" '
    # The same rule local_sessions applied to the sessions on this machine.
    # A guest running this script has already applied it to what it publishes,
    # so this is what keeps a guest that has not been rebuilt yet -- whose
    # sessions say nothing about which agent is driving them -- from putting
    # its console work in the row.
    #
    # No apostrophes in here: the jq program is single-quoted, and one would
    # end it.
    def keep:
      $filter == "all" or (.agent == "zed" and (.conversation == true));

    # Two characters of a project name: the first two letters, since a project
    # name is a word rather than a derived session name with its
    # distinguishing part on the end.
    def projectChip($name):
      (($name // "") | ascii_upcase | gsub("[^A-Z0-9]"; ""))[0:2];

    # One square per project, not per thread.
    #
    # A click can only ever land on a project: Zed has no way in from outside
    # to select one thread of several -- its CLI knows paths and nothing else,
    # and the selection in the panel lives in its own sqlite -- so a square per
    # thread promised something the click could not keep. A square per project
    # says exactly what clicking it does.
    #
    # Done here rather than in local_sessions so it covers the sessions other
    # machines publish as well. A guest running this same script has grouped
    # its own already, which is why the thread count is summed rather than
    # counted: one square standing for three threads has to contribute three.
    #
    # Only the editor threads are grouped. A session in a terminal is reached
    # through its own process and tab, so it stays a square of its own -- which
    # only shows up under CLAUDE_READY_AGENTS=all anyway.
    #
    # Grouped by cwd rather than by name: a thread given its own git worktree
    # (see the swarm note in zed.nix) is a different checkout and gets its own
    # window, so it is honestly a different square.
    def byProject:
      [ .[] | select(.agent != "zed") ]
      + ( [ .[] | select(.agent == "zed") ]
          | group_by([ .origin, (.cwd // "") ])
          | map(
              (sort_by(.startedAt // 0) | last) as $newest
              | (($newest.cwd // "") | split("/") | last) as $project
              | $newest + {
                  name: $project,
                  # The project is the label and the tooltip line now, so the
                  # topic of whichever thread happened to be newest would be a
                  # caption for the wrong thing.
                  topic: null,
                  label: projectChip($project),
                  # Waiting on you beats working: that is what a glance at the
                  # bar is for, and a project with one thread done and two
                  # still going is a project worth going to.
                  status: (
                    if any(.[]; .status == "waiting") then "waiting"
                    elif any(.[]; .status == "idle") then "idle"
                    else "busy" end
                  ),
                  threads: (map(.threads // 1) | add),
                }
            )
        );

    (($here + ($elsewhere | map(select(keep)))) | byProject) as $sessions
    | {
        ready: ([$sessions[] | select(.status == "idle" or .status == "waiting")] | length),
        busy: ([$sessions[] | select(.status == "busy")] | length),
        total: ($sessions | length),
        sessions: $sessions,
      }
    | .state = (if .ready > 0 then "ready" elif .busy > 0 then "busy" else "none" end)
  '
}

while :; do
  # Printed every pass, changed or not. Reading the registries costs the same
  # either way, and a heartbeat is what lets a consumer tell a watcher that
  # died from a desktop that simply went quiet.
  line=$(snapshot) || line=""
  if [ -n "$line" ]; then
    if [ -n "$destination" ]; then
      # Written whole: a reader on the other side of a share should never see
      # half a reading, and the rewrite is also this publisher's heartbeat.
      printf '%s\n' "$line" > "$destination.tmp" && mv -f "$destination.tmp" "$destination"
    else
      printf '%s\n' "$line"
    fi
  fi

  # Every status flip rewrites <pid>.json in a registry, so inotify makes this
  # event-driven; the timeout is only a backstop for an event we missed, and
  # the heartbeat consumers measure staleness against. Published readings are
  # watched by their directory rather than by name, since each one arrives as a
  # rename over the last.
  mapfile -t dirs < <(session_dirs; remote_dirs)
  if [ "${#dirs[@]}" -eq 0 ]; then
    sleep 60
  else
    inotifywait -q -t 60 -e create,modify,delete,move,close_write "${dirs[@]}" >/dev/null 2>&1
  fi

  # Collapse a burst of registry writes into one reading, and keep the loop
  # bounded even if the watch above cannot start at all.
  sleep 1
done

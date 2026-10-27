# Board

One card per file. corkboard shows this directory as a board and updates
live when a file changes.

Front matter (flat `key: value` lines between `---`):

- `title`: one line.
- `status`: backlog | ready | doing | review | done
- `agent`: who is working on it; empty when nobody is.
- `agent_state`: queued | working | blocked | needs-review | done
- `rank`: optional number; lower sorts first within a column.

If you are an agent working on a card:

- When you start, set `status: doing`, `agent: <your name>`, `agent_state: working`.
- If you need a human decision, set `agent_state: blocked` and say what you
  need as the last entry under `## Log`.
- When you finish, set `status: review`, `agent_state: needs-review`, and log
  what changed and how you verified it.
- Append to `## Log` as `- <ISO time> <name>: <note>`; never rewrite earlier entries.
- You may create cards for follow-up work you discover; put them in `backlog`.

--!nonstrict
-- The dropdown behind the bar line: the whole day as a list, one row per
-- block, with the one running marked and the ones already over greyed.
--
-- A view only. Nothing here writes to the calendar -- changing the plan goes
-- through Claude, which is the only thing that knows why a block is where it
-- is -- so the two buttons at the bottom are the two things that are
-- genuinely local: open a chat to re-plan, and skip the gate for today.
--
-- Same stream as block.luau, and deliberately so: both halves decode one
-- reading of the day, so the line in the bar and the list under it cannot
-- disagree about which block is running.

local DAYPLAN = "@dayplan@"
local PLAN = @planCommand@

local ROW = 30
local GAP = 2

-- What the panel height in plugin.toml was calculated from. A day runs 8-14
-- blocks; a plan longer than this gets its tail cut rather than drawn past the
-- bottom edge, and the last row says how many were dropped.
local MAX_ROWS = 14

local reading = { state = "unsynced", blocks = {} }
local streaming = false

local WHEN = {
  now = { glyph = "player-play", color = "primary" },
  past = { glyph = "check", color = "on_surface_variant" },
  later = { glyph = "point", color = "on_surface" },
}

local function row(block)
  local style = WHEN[block.when] or WHEN.later

  return ui.row({
    key = block.start .. block.title,
    height = ROW,
    width = "fill",
    align = "center",
    gap = 8,
  }, {
    ui.glyph({ key = "mark", name = style.glyph, size = 14, color = style.color }),
    -- The time is boxed to a fixed width rather than given one of its own:
    -- width is a container property here, and a row of labels that each size
    -- to their text leaves a ragged column of start times, which is the thing
    -- that makes a list like this unreadable at a glance.
    ui.row({ key = "time", width = 56, align = "center" }, {
      ui.label({ key = "at", text = block.start, fontSize = 12, color = "on_surface_variant" }),
    }),
    ui.label({
      key = "title",
      text = block.title,
      fontSize = 13,
      -- Only the block in force is bold. Everything on this list is something
      -- he agreed to do, so weight has to mean "this one, now".
      fontWeight = block.when == "now" and "bold" or "normal",
      color = style.color,
    }),
  })
end

local function render()
  local rows = {}

  -- The date, and a word about the gate. Deliberately not the bar's own line:
  -- that is on screen six pixels above this, and repeating it here would cost
  -- the width that the block titles need.
  local STATES = {
    locked = { text = "not planned yet", color = "error" },
    meditating = { text = "meditating", color = "secondary" },
    unsynced = { text = "calendar not synced", color = "tertiary" },
    done = { text = "done for the day", color = "on_surface_variant" },
  }
  local status = STATES[reading.state]

  table.insert(rows, ui.row({ key = "header", height = ROW, width = "fill", align = "center", gap = 8 }, {
    ui.label({ key = "date", text = reading.date or "Today", fontSize = 13, fontWeight = "bold" }),
    ui.label({
      key = "state",
      text = status and status.text or "",
      fontSize = 11,
      color = status and status.color or "on_surface_variant",
    }),
  }))

  local blocks = reading.blocks or {}
  for index, block in ipairs(blocks) do
    if index > MAX_ROWS then
      table.insert(rows, ui.label({
        key = "overflow",
        text = "+ " .. tostring(#blocks - MAX_ROWS) .. " more \u{2014} see `dayplan today`",
        fontSize = 11,
        color = "on_surface_variant",
      }))
      break
    end
    table.insert(rows, row(block))
  end

  if #blocks == 0 then
    table.insert(rows, ui.label({
      key = "empty",
      text = 'Nothing planned. Say "plan my day" to ' .. (reading.assistant or "Claude") .. ".",
      fontSize = 12,
      color = "on_surface_variant",
    }))
  end

  table.insert(rows, ui.row({ key = "actions", height = ROW + 4, width = "fill", gap = GAP }, {
    ui.button({
      key = "plan",
      glyph = "message",
      text = "Plan with " .. (reading.assistant or "Claude"),
      variant = "ghost",
      height = ROW,
      width = "fill",
      onClick = function()
        noctalia.runAsync(PLAN)
        panel.close()
      end,
    }),
    ui.button({
      key = "meditate",
      glyph = "yoga",
      text = "Meditate",
      variant = "ghost",
      height = ROW,
      width = "fill",
      onClick = function()
        noctalia.runAsync({ DAYPLAN, "meditate" })
        panel.close()
      end,
    }),
    -- Deliberately plain rather than hidden behind a confirmation: a gate you
    -- cannot open is a gate that gets ripped out of the config at 8am. It is
    -- logged, which is the honest version of friction.
    ui.button({
      key = "skip",
      glyph = "lock-open",
      text = "Skip today",
      variant = "ghost",
      height = ROW,
      width = "fill",
      onClick = function()
        noctalia.runAsync({ DAYPLAN, "skip" })
        panel.close()
      end,
    }),
  }))

  -- Centred for the same reason the brightness panel is: the height is
  -- declared in the manifest and cannot be measured from a list whose length
  -- changes daily, so the slack has to land somewhere, and split in two it
  -- reads as padding.
  panel.render(ui.column({
    gap = GAP,
    padding = 10,
    align = "stretch",
    justify = "center",
  }, rows))
end

local function startStream()
  streaming = noctalia.runStream(DAYPLAN .. " watch", function(line)
    local decoded = noctalia.json.decode(line)
    if type(decoded) == "table" and decoded.state ~= nil then
      reading = decoded
      render()
    end
  end)
end

-- Rendered on open rather than only at load: the panel is off screen between
-- an open and a close, and the day has moved on while it was away.
function onOpen(_context)
  render()
  if not streaming then
    startStream()
  end
end

render()
startStream()

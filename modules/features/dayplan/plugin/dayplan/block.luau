--!nonstrict
-- Bar widget: the block that is supposed to be running, how much of it is
-- left, and what comes after it. Clicking opens the whole day (today.luau).
--
-- Before the morning plan is approved this is a padlock and the words "Plan
-- your day first", which is the same reading the daemon is acting on when it
-- closes a YouTube window -- so the bar explains what just happened rather
-- than leaving it as a window that vanished.
--
-- Nothing here reads the calendar. `dayplan watch` holds that and prints a
-- JSON reading whenever it changes, so this side never polls; update() is only
-- here to notice a stream that has died and left the bar frozen on a block
-- that finished an hour ago.

local DAYPLAN = "@dayplan@"

-- Long titles are the norm -- "Bot: wire the pons launchpad deposit call" --
-- and the bar has a workspace list and the window title to its left. Elided
-- rather than wrapped or left to push the rest of the bar along.
local MAX_CHARS = 34

-- The watcher prints at least once every 50s even when nothing changed, so a
-- longer silence than this means it is gone rather than that the day is quiet.
local STALE_MS = 150000

-- The panel entry this opens, by full id: author/plugin:entry.
local PANEL = "jurenka/dayplan:today"

-- Which palette role carries each state. The locked state is the only one that
-- is a demand rather than a reading, and it is the one the daemon is enforcing
-- while it shows, so it gets `error`.
local COLORS = {
  locked = "error",
  meditating = "secondary",
  running = "primary",
  gap = "on_surface_variant",
  done = "on_surface_variant",
  unsynced = "tertiary",
}

local reading = { state = "unsynced", text = "dayplan", glyph = "calendar-off" }
local lastLineMs = 0
local streaming = false

-- Counted and cut in characters rather than bytes: the readings carry "·" and
-- an arrow, and a byte-wise cut through one of those leaves a broken glyph in
-- the bar. utf8.len returns nil on invalid input, which is the one case worth
-- passing through untouched rather than guessing at.
local function elide(text)
  local chars = utf8.len(text)
  if chars ~= nil and chars > MAX_CHARS then
    return string.sub(text, 1, utf8.offset(text, MAX_CHARS) - 1) .. "\u{2026}"
  end
  return text
end

local function render()
  local color = COLORS[reading.state] or "on_surface"

  local nodes = {
    ui.glyph({ key = "glyph", name = reading.glyph or "calendar", size = 16, color = color }),
    ui.label({ key = "text", text = elide(reading.text or ""), color = color }),
  }

  -- Filled and coloured while this laptop's time is coming off the allowance.
  local allowance = reading.allowance
  if allowance ~= nil then
    local spending = allowance.counting and "tertiary" or "on_surface_variant"
    table.insert(nodes, ui.glyph({ key = "allowance", name = allowance.counting and "hourglass-filled" or "hourglass", size = 16, color = spending }))
    table.insert(nodes, ui.label({ key = "allowance-left", text = allowance.left, color = spending }))
  end

  -- Stack along the bar, so a side bar gets a column rather than a row running
  -- off the edge of it. Same shape as the Claude status widget next to it.
  local container = barWidget.isVertical() and ui.column or ui.row

  barWidget.setVisible(true)
  barWidget.render(container({ gap = 6, align = "center" }, nodes))

  -- The tooltip is the description Claude wrote on the block, which is the
  -- first physical step of it -- the thing worth having on hover, because the
  -- title alone is what you already know and are avoiding.
  local rows = {}
  if reading.tooltip ~= nil and reading.tooltip ~= "" then
    table.insert(rows, { key = reading.date or "Today", value = reading.tooltip })
  end
  if reading.next ~= nil and reading.next ~= "" then
    table.insert(rows, { key = "Next", value = reading.next })
  end
  if #rows > 0 then
    barWidget.setTooltip(rows)
  else
    barWidget.setTooltip(reading.text or "")
  end
end

local function startStream()
  streaming = noctalia.runStream(DAYPLAN .. " watch", function(line)
    local decoded = noctalia.json.decode(line)
    if type(decoded) == "table" and decoded.state ~= nil then
      reading = decoded
      lastLineMs = noctalia.nowMs()
      render()
    end
  end)
  if streaming then
    lastLineMs = noctalia.nowMs()
  end
end

function onClick()
  noctalia.togglePanel(PANEL)
end

function update()
  noctalia.setUpdateInterval(60000)
  if not streaming or (noctalia.nowMs() - lastLineMs) > STALE_MS then
    startStream()
  end
end

render()
startStream()

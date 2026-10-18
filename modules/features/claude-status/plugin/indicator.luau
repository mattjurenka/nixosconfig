--!nonstrict
-- Bar widget: how much of the plan is spent, then one square per project with
-- agent threads in it. A project with a thread waiting on you is a filled
-- square in the primary colour; one whose threads are all still working is an
-- outline in the secondary. Either way the square carries two characters of
-- the project name, which is what tells one square from the next.
--
-- The squares are the same ones the corner overlay draws over a fullscreen
-- window, so the readout looks the same whichever surface is showing it.
--
-- Clicking a square goes to that project in Zed: its window, or a new one over
-- SSH for a project in an agent VM. Which thread the panel then shows is
-- Zed's own business -- nothing outside the editor can select one -- and that
-- is the reason a square is a project rather than a thread. Clicking the
-- capsule around them opens Zed itself.
--
-- Session readings arrive on stdout of the watcher, one JSON line per change,
-- so that side never polls; update() exists only to notice a stream that has
-- died.

local WATCH = "@watch@"
local USAGE = "@usage@"
local FOCUS = "@focus@"
local AGENTS = "@agents@"

local SQUARE = 18
local GAP = 4

-- Two characters of the project name, written across its square, so a row of
-- them says which project is which rather than only how many there are. Two is
-- what fits: the squares are small on purpose, and the pair is there to be
-- told apart at a glance, not read as a word. The watcher decides what they
-- are; this only draws them.
local LABEL_SIZE = 10

-- A session that is still working is drawn as an outline rather than a block.
-- Colour says the same thing and is the better signal on a desktop, but the
-- phone widget showing this same reading cannot keep it -- One UI paints a
-- lock screen complication in a single colour whatever it is handed -- so
-- shape carries the reading too, and the two surfaces stay the same readout.
--
-- `border` is the colour and `borderWidth` the thickness. A box given a
-- border leaves its inside transparent, which is what lets the bar show
-- through an outlined square; a box given neither draws black.
--
-- Thinner than it was, because the border eats into the room the label has:
-- a 3px border on both sides leaves an 18px square 12px to write two
-- characters across, which is less than the same two get on a filled one.
local BORDER = 2

-- The watcher prints a line at least once a minute even when nothing has
-- changed, so silence this long means it is gone rather than that the desktop
-- is quiet.
local STALE_MS = 300000

local snapshot = { state = "none", ready = 0, busy = 0, total = 0, sessions = {} }
local lastLineMs = 0
local streaming = false

-- The plan reading, or nil until the first one arrives. Its own stream and its
-- own staleness: the session watcher can be perfectly healthy while this
-- machine is offline and the usage endpoint is unreachable, and the other way
-- round on a host that has no credentials at all.
local usage = nil
local lastUsageMs = 0
local streamingUsage = false

-- Tabler's `percentage-N` glyphs are pie circles that fill as N rises, which is
-- the whole indicator: one circle per limit. The font also carries 25/33/66/75,
-- but mixing step sizes would make the pie jump unevenly, so only the deciles
-- are used and the reading is rounded to one.
local USAGE_STEP = 10

-- A limit is worth noticing well before it runs out.
local USAGE_WARN = 60
local USAGE_HIGH = 85

local function isReady(status)
  return status == "idle" or status == "waiting"
end

local function usageColor(percent)
  if percent >= USAGE_HIGH then
    return "error"
  elseif percent >= USAGE_WARN then
    return "tertiary"
  end
  return "primary"
end

-- Nearest decile, so a circle never claims to be emptier or fuller than the
-- reading by more than half a step.
local function usageGlyph(percent)
  local step = math.floor((percent / USAGE_STEP) + 0.5) * USAGE_STEP
  if step < 0 then
    step = 0
  elseif step > 100 then
    step = 100
  end
  return "percentage-" .. tostring(step)
end

-- The two limits, left to right, as circles plus the tooltip lines that say
-- which is which. They are independent of each other: the week can be the one
-- about to run out while the session window has barely been touched, so a
-- single circle could not stand in for both.
local function usageNodes()
  local nodes = {}
  local rows = {}

  if usage == nil then
    return nodes, rows
  end

  local limits = {
    { key = "session", label = "5h window", percent = usage.percent, resets = usage.resets },
    { key = "weekly", label = "week", percent = usage.weekly, resets = usage.weeklyResets },
  }

  for _, limit in ipairs(limits) do
    if type(limit.percent) == "number" then
      table.insert(nodes, ui.glyph({
        key = limit.key,
        name = usageGlyph(limit.percent),
        size = SQUARE,
        color = usageColor(limit.percent),
      }))

      local value = tostring(limit.percent) .. "%"
      if limit.resets ~= nil and limit.resets ~= "" then
        value = value .. " \u{00B7} resets " .. limit.resets
      end
      table.insert(rows, { key = limit.label, value = value })
    end
  end

  return nodes, rows
end

local function render()
  local sessions = snapshot.sessions or {}
  local nodes, rows = usageNodes()

  -- The plan reading stands on its own: it is worth seeing when nothing is
  -- running, which is exactly when deciding whether to start something is a
  -- question about what is left in the window.
  if #sessions == 0 and #nodes == 0 then
    barWidget.setVisible(false)
    return
  end

  for index, session in ipairs(sessions) do
    -- Encoded per render rather than per click: the closure is replaced on the
    -- next reading anyway, so it should carry that reading's session, not a
    -- reference to whatever the table holds by the time it is clicked.
    local record = noctalia.json.encode(session) or ""

    -- Both properties are always set, and the key carries the state. The
    -- renderer keeps a keyed node across renders and merges the props it is
    -- given onto it, so a square that was filled and is now an outline would
    -- otherwise keep its old fill and come out as a filled square with a
    -- border around it. Naming the state in the key retires the old node
    -- instead; setting both properties makes it right either way.
    local ready = isReady(session.status)

    -- A row rather than a box because the square now has something in it, and
    -- ui.box takes no children. Everything else about it is the same square:
    -- the size is explicit, so a label never stretches it, and a long label
    -- would be clipped rather than push its neighbours along the bar.
    local label = session.label or ""
    local children = {}
    if label ~= "" then
      table.insert(children, ui.label({
        text = label,
        fontSize = LABEL_SIZE,
        fontWeight = "bold",
        -- A filled square's label has to come off the fill, not off the bar,
        -- so it takes the palette's companion colour rather than the bar's
        -- foreground. An outlined square is still showing the bar through it,
        -- and reads in the same colour as its own border.
        color = ready and "on_primary" or "secondary",
      }))
    end

    table.insert(nodes, ui.row({
      -- Keyed by position so a square keeps its identity across renders; the
      -- watcher orders sessions by start time, so they never shuffle.
      key = tostring(index) .. (ready and "-ready" or "-busy"),
      width = SQUARE,
      height = SQUARE,
      -- A row stretches its children across its height by default, which on a
      -- single label means a 10px glyph dragged to 18px tall; centring on both
      -- axes is what puts the two characters in the middle of the square.
      align = "center",
      justify = "center",
      fill = ready and "primary" or "transparent",
      border = ready and "transparent" or "secondary",
      borderWidth = ready and 0 or BORDER,
      onClick = function()
        noctalia.runAsync({ FOCUS, record })
      end,
    }, children))

    local status = session.status
    if status == "idle" then
      status = "ready"
    elseif status == "waiting" then
      status = "waiting on you"
    end
    -- The project name, which is what the two characters on the square are
    -- short for, so hovering is how a label gets explained. The count is what
    -- says whether "ready" means the one thread in there or one of several,
    -- and the machine is named for a project that is not on this one.
    local threads = session.threads or 1
    if threads > 1 then
      status = status .. " \u{00B7} " .. tostring(threads) .. " threads"
    end

    -- Not `label`: that name is taken a few lines up by the two characters
    -- drawn on the square itself.
    local line = session.name or session.topic
    if session.origin ~= nil and session.origin ~= "local" then
      line = line .. " (" .. session.origin .. ")"
    end

    table.insert(rows, { key = line, value = status })
  end

  -- Stack along the bar, so a side bar gets a column of squares rather than a
  -- row running off the edge of it.
  local container = barWidget.isVertical() and ui.column or ui.row

  barWidget.setVisible(true)
  barWidget.render(container({ gap = GAP, align = "center" }, nodes))
  barWidget.setTooltip(rows)
end

local function startStream()
  streaming = noctalia.runStream(WATCH, function(line)
    local decoded = noctalia.json.decode(line)
    if type(decoded) == "table" and decoded.state ~= nil then
      snapshot = decoded
      lastLineMs = noctalia.nowMs()
      render()
    end
  end)
  if streaming then
    lastLineMs = noctalia.nowMs()
  end
end

local function startUsageStream()
  streamingUsage = noctalia.runStream(USAGE, function(line)
    local decoded = noctalia.json.decode(line)
    if type(decoded) == "table" and (decoded.percent ~= nil or decoded.weekly ~= nil) then
      usage = decoded
      lastUsageMs = noctalia.nowMs()
      render()
    end
  end)
  if streamingUsage then
    lastUsageMs = noctalia.nowMs()
  end
end

function update()
  noctalia.setUpdateInterval(60000)
  -- A watcher that died leaves the widget frozen on a stale reading, which is
  -- worse than no widget at all. Notice, and start it again.
  if not streaming or (noctalia.nowMs() - lastLineMs) > STALE_MS then
    startStream()
  end
  if not streamingUsage or (noctalia.nowMs() - lastUsageMs) > STALE_MS then
    startUsageStream()
  end
end

function onClick()
  noctalia.runAsync(AGENTS)
end

barWidget.setVisible(false)
startStream()
startUsageStream()

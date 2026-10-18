--!nonstrict
-- The dropdown behind the bar glyph: the four modes as a vertical list, one
-- row each, the one in force marked.
--
-- Why a panel rather than a menu: noctalia has a native context menu for
-- plugins (panel.openContextMenu), but it needs plugin_api 28 and has to be
-- raised from onRightClick, which is the one callback carrying the pointer
-- serial a popup needs. This shell is 5.2.1, whose ceiling is 26, and the ask
-- was a left click on the icon -- so the list is a panel entry, which is a
-- surface of its own and opens from anywhere.
--
-- The rows do not touch the backlight either; see buttons.luau. They name a
-- mode and the service acts on it, so this stays a view of state that someone
-- else owns.

local MODE = "@mode@"

-- Spelled out here rather than two characters of glyph: a list has room for
-- the sentence, and the sentence is what makes "adaptive" mean something to
-- anyone who has not read sun-brightness.sh.
local PRESETS = {
  { key = "min", glyph = "brightness-low", text = "Minimum" },
  { key = "half", glyph = "contrast-filled", text = "Half" },
  { key = "max", glyph = "brightness-high", text = "Full" },
  { key = "adaptive", glyph = "sunrise", text = "Follow the sun" },
}

local mode = "adaptive"
local streaming = false

local function render()
  local rows = {}

  for _, preset in ipairs(PRESETS) do
    table.insert(rows, ui.button({
      -- Keyed so the host keeps each row across renders and only repaints what
      -- the mode stream actually changed.
      key = preset.key,
      glyph = preset.glyph,
      text = preset.text,
      -- Ghost everywhere, so `selected` is the only thing drawing a
      -- background: the same trick the bar row used to tell the active mode
      -- apart from the other three.
      variant = "ghost",
      -- Pinned in pixels rather than left to controlSize: the panel height is
      -- declared in the manifest and cannot measure its contents, so the rows
      -- have to be the known quantity. Four of these plus the gaps and the
      -- padding are what the height there adds up to -- "md" turned out taller
      -- than that sum assumed, which clipped the last row.
      height = 34,
      selected = mode == preset.key,
      -- A row is as wide as the panel, and its label starts at the left edge
      -- under the one above it. Centred text in a column of four reads as four
      -- buttons rather than as a list.
      contentAlign = "start",
      width = "fill",
      onClick = function()
        -- Fire and forget, then get out of the way: the mode stream is what
        -- tells the bar glyph and this list what actually happened, and a
        -- dropdown that stays open after a choice has to be dismissed by hand.
        noctalia.runAsync({ MODE, preset.key })
        panel.close()
      end,
    }))
  end

  -- Centred rather than stacked from the top, which is what keeps the gap
  -- above the first row and below the last one equal. The panel height is
  -- declared in the manifest and the host adds chrome of its own that nothing
  -- here can measure, so the leftover few pixels have to land somewhere: split
  -- in two they read as padding, all at the bottom they read as a mistake --
  -- and all at the bottom is what "no padding below Follow the sun" was.
  panel.render(ui.column({
    gap = 2,
    padding = 8,
    align = "stretch",
    justify = "center",
  }, rows))
end

local function startStream()
  streaming = noctalia.runStream(MODE .. " watch", function(line)
    local nextMode = line:gsub("%s+", "")
    if nextMode ~= "" and nextMode ~= mode then
      mode = nextMode
      render()
    end
  end)
end

-- Rendered on open rather than once at load: the panel is only on screen
-- between an open and a close, and the mode may have moved while it was away.
function onOpen(_context)
  render()
  if not streaming then
    startStream()
  end
end

render()
startStream()

--!nonstrict
-- Bar widget: one glyph that says what the backlight should be doing, and
-- opens the list of the four modes when clicked.
--
-- Three of the modes are fixed presets. The fourth hands the panel back to the
-- sun-following curve in sun-brightness.sh, which is the closest this machine
-- can get to adapting to the room -- it has no ambient light sensor, so the
-- sun's position is standing in for one.
--
-- The widget does not touch the backlight itself. It names a mode, and the
-- service that owns the panel acts on it; one writer means a preset and the
-- curve can never race each other. The glyph comes from the same state the
-- service reads, streamed rather than remembered, so it stays honest when the
-- mode is changed from a shell instead of from here.
--
-- This was four buttons in the bar until 2026-10-17. One glyph plus a dropdown
-- (panel.luau) costs a click to change mode and buys back three bar slots --
-- and the glyph still says which mode is in force without being clicked, which
-- is the part the row was really there for.
--
-- The entry is still called `buttons` on purpose: the bar names its widgets by
-- entry id in noctalia's *runtime* settings.toml, which the declarative
-- config does not replace (see the note in noctalia.nix), so renaming it here
-- would drop the widget out of the bar with nothing saying why.
--
-- Night light is deliberately not one of these modes. Its forced state lives
-- only in noctalia's running GammaService and is never written to the config,
-- so a row here could toggle it but could never show it; noctalia's own
-- `nightlight` widget sits next to this one in the bar and does both.

local MODE = "@mode@"

-- The panel entry this glyph opens, by full id, which is what togglePanel
-- takes: author/plugin:entry, the `modes` entry in plugin.toml.
local PANEL = "jurenka/brightness-modes:modes"

local MODES = {
  min = { glyph = "brightness-low", tooltip = "Minimum brightness" },
  half = { glyph = "contrast-filled", tooltip = "Half brightness" },
  max = { glyph = "brightness-high", tooltip = "Full brightness" },
  adaptive = { glyph = "sunrise", tooltip = "Adaptive: follow the sun" },
}

local mode = "adaptive"
local streaming = false

local function render()
  local current = MODES[mode] or MODES.adaptive

  -- Imperative, not a ui.button of our own, and that is the whole point: this
  -- way noctalia draws its own bar capsule around the glyph and the hover is
  -- the pill every other bar item has. Rendering a button here brought its own
  -- square background along with it -- right for a control inside a panel,
  -- wrong for an item in the bar.
  barWidget.setGlyph(current.glyph)
  -- The mode is in the tooltip as well as the glyph: the glyphs are legible
  -- once you know them, and this is how you learn them.
  barWidget.setTooltip(current.tooltip)
end

-- The widget is one control now, so the click belongs to the widget rather
-- than to a button inside it.
function onClick()
  noctalia.togglePanel(PANEL)
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

function update()
  -- The stream is silent between changes, so this is only here to notice one
  -- that has died and left the glyph frozen on a mode that is no longer true.
  noctalia.setUpdateInterval(60000)
  if not streaming then
    startStream()
  end
end

render()
startStream()

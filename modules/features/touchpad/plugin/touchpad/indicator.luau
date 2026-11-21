--!nonstrict
-- Bar widget: a finger while the touchpad is on, a struck-through one while
-- it is off. A click switches it, same as Mod+T.
--
-- The state is streamed from `touchpad watch` rather than kept here, so the
-- glyph follows the key and a shell as well as its own clicks.

local TOUCHPAD = "@touchpad@"

local STATES = {
  on = { glyph = "hand-finger", tooltip = "Touchpad on" },
  off = { glyph = "hand-finger-off", tooltip = "Touchpad off" },
}

local state = "on"
local streaming = false

local function render()
  local current = STATES[state] or STATES.on
  barWidget.setGlyph(current.glyph)
  barWidget.setTooltip(current.tooltip)
end

function onClick()
  noctalia.runAsync({ TOUCHPAD, "toggle" })
end

local function startStream()
  streaming = noctalia.runStream(TOUCHPAD .. " watch", function(line)
    local nextState = line:gsub("%s+", "")
    if nextState ~= "" and nextState ~= state then
      state = nextState
      render()
    end
  end)
end

function update()
  -- Only here to restart a stream that has died.
  noctalia.setUpdateInterval(60000)
  if not streaming then
    startStream()
  end
end

render()
startStream()

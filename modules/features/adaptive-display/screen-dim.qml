// A black sheet over every output, for the stretch of the evening below the
// point where the backlight has nothing left to give.
//
// This panel bottoms out in hardware well above off: asked for 0 through
// logind it still reports an actual_brightness of 3084 out of 65535, which is
// the same ~4.7% it sits at when asked for the 5% floor. So the backlight is
// already spent at dusk, and anything darker has to come from somewhere else.
//
// The obvious somewhere else is gamma, and it is taken: noctalia grabs
// wlr-gamma-control on eDP-1 when the shell starts and holds it for the
// session, whether or not night light is enabled -- a second client gets
// gamma_control::Event::Failed and nothing else. Scaling the ramp would mean
// giving up noctalia's night light entirely and re-homing the colour
// temperature ramp here, which is a large change to win the same pixels.
//
// So: compose instead. An alpha-blended black layer over the screen is the
// same multiply a gamma ramp would apply, arriving one stage later in the
// pipeline. The cost of arriving later is that it is part of the image --
// screenshots and screen shares come out dim too. That is the trade this file
// is, and the reason it is worth it is that it needs nothing from noctalia.
//
// Screenshots get out of the trade by asking: screenshot-region.sh calls
// `hide` over quickshell's IPC just before noctalia freezes the screen and
// `restore` once it has, so the sheet is gone for the one frame that is
// captured. Screen shares still come out dim.
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick

ShellRoot {
  id: root

  // 0 is the panel as it comes. sun-brightness.sh owns this value; the file is
  // the whole interface between the two, so the service can be restarted,
  // debugged or run by hand in a terminal without this process knowing.
  property real dim: 0.0

  // Out of the way of a screenshot (see the top of this file). Set by IPC
  // rather than the dim file, which belongs to sun-brightness.
  property bool hidden: false

  IpcHandler {
    target: "screenDim"
    function hide(): void { root.hidden = true; }
    function restore(): void { root.hidden = false; }
  }

  // Deliberately short of 1.0: a fully opaque sheet is a black screen whose
  // only way back is the thing that put it there, which is the same reason
  // minBrightness is not 0.
  readonly property real maxDim: 0.9

  FileView {
    id: dimFile
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/adaptive-display/dim"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      // A truncate-then-write can be read in the gap between the two, so a
      // value that does not parse means "caught mid-write", not "go dark".
      // Holding the last good one is right either way: the write that
      // follows lands as another change and we read it then.
      const next = parseFloat(dimFile.text());
      if (!isNaN(next)) {
        root.dim = Math.max(0.0, Math.min(root.maxDim, next));
      }
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData
      screen: modelData

      // Overlay rather than Top: the bar, the notifications and the launcher
      // all want dimming too, and a sheet under them would leave the brightest
      // things on the screen at full strength. Same-layer surfaces stack in
      // the order they arrive, and this one starts with the session.
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "screen-dim"
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // The whole output, reserving none of it: an exclusive zone here would
      // push every other layer surface out of the way of a sheet that is not
      // meant to take up room.
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore

      // An empty input region. Without it this is a fullscreen window that
      // eats every click on the desktop, which is the one failure mode here
      // that would be hard to get out of.
      mask: Region {}

      color: "transparent"

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, root.dim)
        // Instant, unlike the colour: a fade out would still be on screen
        // when the frame is captured.
        opacity: root.hidden ? 0 : 1

        // Matched to the backlight's own fade so a tick that moves both does
        // not read as two separate events.
        Behavior on color {
          ColorAnimation { duration: 400; easing.type: Easing.OutQuad }
        }
      }
    }
  }
}

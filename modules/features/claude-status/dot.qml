// One 18x18 square per Claude Code session, in a row in the very top-left
// corner, on the overlay layer so it stays visible over a fullscreen window --
// which is exactly when it is shown, because that is when niri covers the bar
// (and the bar widget drawing the same row with it).
//
// A session waiting on you is a filled square; one still working is an
// outline. The same encoding the bar widget and the phone widget use, so the
// readout is the same wherever it is being shown -- with the labels as the one
// exception: these squares carry two characters of their project name, the
// way the bar's do, and the phone's deliberately carry nothing, because what
// goes to a public relay is counts and nothing that names the work.
//
// Clicking a square goes to that session, through the same script the bar
// widget clicks through.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // One entry per session, in start order; and the outputs that currently
    // have a fullscreen window. Both arrive as JSON lines from their watcher.
    property var sessions: []
    property var fullscreenOutputs: []

    readonly property color readyColor: "@readyColor@"
    readonly property color busyColor: "@busyColor@"

    // A filled square's label has to come off the fill rather than off
    // whatever the fullscreen window happens to be showing behind it, so it is
    // drawn in the colour the fill is a companion to. An outlined square still
    // shows that window through it, and reads in its own border colour.
    readonly property color readyLabelColor: "@readyLabelColor@"

    readonly property int squareSize: 18
    // Thin, because the border eats into the room the label has; see the same
    // note in the bar widget, which draws this row at the same sizes.
    readonly property int border: 2
    readonly property int labelSize: 10
    readonly property int gap: 4

    function isReady(status) {
        return status === "idle" || status === "waiting";
    }

    Process {
        running: true
        command: ["@claudeWatch@"]
        stdout: SplitParser {
            onRead: line => {
                try {
                    root.sessions = JSON.parse(line).sessions ?? [];
                } catch (e) {}
            }
        }
    }

    Process {
        running: true
        command: ["@fullscreenWatch@"]
        stdout: SplitParser {
            onRead: line => {
                try {
                    root.fullscreenOutputs = JSON.parse(line);
                } catch (e) {}
            }
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            required property var modelData

            screen: modelData
            visible: root.sessions.length > 0
                && root.fullscreenOutputs.indexOf(modelData.name) !== -1

            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "claude-ready-dot"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            anchors.top: true
            anchors.left: true
            // Ignore the bar's reserved strip: the squares belong in the corner
            // the fullscreen window is using, not below a bar that is not drawn.
            exclusionMode: ExclusionMode.Ignore
            implicitWidth: Math.max(1, row.width)
            implicitHeight: root.squareSize

            // The gaps between squares show the window underneath, so the row
            // reads as separate squares rather than one bar.
            color: "transparent"

            // The squares take a click so they can be clicked; everything
            // else about this window does not, so the rest of the fullscreen
            // window underneath keeps working. The region is the row itself,
            // which is only as wide as there are sessions -- a 16px strip in
            // the corner, not the corner gesture area at large.
            mask: Region {
                item: row
            }

            Row {
                id: row

                spacing: root.gap

                Repeater {
                    model: root.sessions

                    Rectangle {
                        id: square

                        required property var modelData

                        readonly property bool ready: root.isReady(modelData.status)
                        readonly property color shade: ready ? root.readyColor : root.busyColor

                        width: root.squareSize
                        height: root.squareSize

                        // Filled when the session is waiting on you, an
                        // outline while it is still working.
                        color: ready ? shade : "transparent"
                        border.color: ready ? "transparent" : shade
                        border.width: ready ? 0 : root.border

                        // Two characters of the project name, the same ones
                        // the bar widget writes across its squares, so a row
                        // of them says which session is which and not only how
                        // many there are. Centred over the square rather than
                        // laid out inside it, so the border cannot push it off
                        // centre; empty until the watcher has a topic to
                        // shorten, which draws nothing at all.
                        Text {
                            anchors.centerIn: parent

                            text: square.modelData.label ?? ""
                            color: square.ready ? root.readyLabelColor : square.shade
                            font.pixelSize: root.labelSize
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor

                            // The whole session record, the way the bar widget
                            // hands it over: the script wants the fields that
                            // say where the session is, not just its name.
                            onClicked: Quickshell.execDetached(["@focus@", JSON.stringify(modelData)])
                        }
                    }
                }
            }
        }
    }
}

# Teach this tty how big the terminal on the far end actually is.
#
# virtio-serial carries bytes and nothing else: no winsize in the protocol, no
# SIGWINCH when the host's window changes. So the only way to learn the size is
# to ask over the byte stream -- park the cursor far off the bottom-right,
# request a cursor-position report, and the terminal answers with where it
# really stopped, which is its size.
#
# CSI 6n rather than CSI 18t: the window-size report is an xterm window
# operation terminals may not implement, while the cursor-position report is
# required by every VT100 descendant. This is what xterm's `resize` does, in 20
# lines rather than a dependency on all of xterm.
set -u

if [ ! -t 0 ]; then
    echo "fit: stdin is not a terminal" >&2
    exit 1
fi

saved=$(stty -g)
# Restore the line discipline on every exit path. A console left in raw mode
# with echo off is indistinguishable from a hung VM.
trap 'stty "$saved" 2>/dev/null || true' EXIT
stty raw -echo min 0 time 10

printf '\033[s\033[9999;9999H\033[6n\033[u'
reply=""
IFS= read -r -d R -t 2 reply || true

stty "$saved" 2>/dev/null || true
trap - EXIT

# The reply is ESC [ <rows> ; <cols> R.
reply="${reply##*\[}"
rows="${reply%%;*}"
cols="${reply##*;}"

case "$rows$cols" in
    "" | *[!0-9]*)
        echo "fit: no usable answer from the terminal; left at $(stty size)" >&2
        exit 1
        ;;
esac

if [ "$rows" -lt 1 ] || [ "$cols" -lt 1 ]; then
    echo "fit: terminal reported ${cols}x${rows}; left at $(stty size)" >&2
    exit 1
fi

stty rows "$rows" cols "$cols"
echo "fit: ${cols}x${rows}"

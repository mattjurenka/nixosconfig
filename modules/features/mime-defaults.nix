# Which program opens what.
#
# This file exists because ~/.config/mimeapps.list was drifting. Nothing
# declared it, so it held whatever the last application to install itself had
# written -- Telegram's tg:// and tonsite:// handlers, Claude Desktop's
# claude://, Claude Code's claude-cli:// -- and nothing else. A .docx had no
# default at all, which is how "I downloaded a Word file and can't open it"
# happens on a machine that is otherwise fully declared.
#
# home-manager writes mimeapps.list *whole* rather than merging into it, so
# everything that was in there by accident has to be in here on purpose. That
# is the point, not a cost: the four scheme handlers below used to exist only
# because two apps had been run at least once, and would have vanished from a
# fresh machine with no sign they were ever expected.
#
# Two consequences worth knowing:
#
#   - An app that writes its own association from now on gets overwritten on
#     the next activation. If a handler should stick, it belongs here.
#   - The first activation has to move the old unmanaged file aside, which is
#     what home-manager.backupFileExtension in home-manager.nix is for.
#     Without it, activation refuses to clobber the file and fails.
#
# Only [Default Applications] is set. [Added Associations] -- which widens the
# "Open With" list -- is left alone, because each program's own desktop file
# already declares the types it can handle, and listing them again here would
# be a second copy of a fact nixpkgs already ships.
{ ... }:
{
  flake.modules.homeManager.mimeDefaults = { ... }:
    let
      # LibreOffice's desktop ids are bare words -- writer.desktop, not
      # org.libreoffice.writer.desktop. Checked against the package rather than
      # guessed, because a default naming a desktop file that does not exist is
      # silently ignored.
      writer = "writer.desktop";
      calc = "calc.desktop";
      impress = "impress.desktop";

      # The PDF reader is the mupdf-backed plugin's entry, not the bare
      # org.pwmt.zathura.desktop, which declares no MimeType at all.
      zathura = "org.pwmt.zathura-pdf-mupdf.desktop";
      loupe = "org.gnome.Loupe.desktop";
      vlc = "vlc.desktop";
      chromium = "chromium-browser.desktop";
      telegram = "org.telegram.desktop.desktop";

      forEach = apps: types: builtins.listToAttrs
        (map (t: { name = t; value = apps; }) types);
    in
    {
      xdg.mimeApps.enable = true;

      xdg.mimeApps.defaultApplications =
        # Word processing. The .docx entry is the one this file was written
        # for; msword and rtf come along because they land in a Downloads
        # folder for the same reasons.
        forEach writer [
          "application/msword"
          "application/rtf"
          "application/vnd.oasis.opendocument.text"
          "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        ]

        # Spreadsheets. text/csv goes to Calc rather than to an editor: a CSV
        # that arrives by download is data to look at in columns, and a CSV
        # being edited as text is being edited in Zed already.
        // forEach calc [
          "application/vnd.ms-excel"
          "application/vnd.oasis.opendocument.spreadsheet"
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
          "text/csv"
        ]

        // forEach impress [
          "application/vnd.ms-powerpoint"
          "application/vnd.oasis.opendocument.presentation"
          "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        ]

        # PDFs and the other paginated formats zathura's mupdf backend reads.
        # An explicit default earns its keep here: LibreOffice Draw also claims
        # application/pdf, and installing the suite would otherwise have made
        # a double-clicked PDF open in a drawing program.
        // forEach zathura [
          "application/pdf"
          "application/epub+zip"
          "application/oxps"
          "application/x-mobipocket-ebook"
        ]

        # Images. Same contest as PDFs and the same reason to be explicit:
        # zathura-pdf-mupdf claims jpeg, png, bmp, tiff and svg as well, and a
        # photo viewer is what should win them.
        // forEach loupe [
          "image/bmp"
          "image/gif"
          "image/jpeg"
          "image/png"
          "image/tiff"
          "image/webp"
        ]
        // forEach chromium [ "image/svg+xml" ]

        // forEach vlc [
          "audio/flac"
          "audio/mpeg"
          "audio/ogg"
          "audio/x-wav"
          "video/mp4"
          "video/quicktime"
          "video/webm"
          "video/x-matroska"
        ]

        # The browser. Declared rather than left to whatever is installed,
        # because something else depends on it: dayplan opens its planning_url
        # through xdg-open when the gate closes a window, and that has to land
        # in a browser rather than nowhere.
        // forEach chromium [
          "text/html"
          "x-scheme-handler/http"
          "x-scheme-handler/https"
        ]

        # The four that were in the file by accident. Telegram writes the first
        # two itself on first run and Claude Desktop the third; the fourth is
        # Claude Code's, whose desktop file lives in
        # ~/.local/share/applications and is not managed by this tree -- so the
        # association is declared here while the handler it points at is still
        # created at runtime.
        // forEach telegram [
          "x-scheme-handler/tg"
          "x-scheme-handler/tonsite"
        ]
        // {
          "x-scheme-handler/claude" = "com.anthropic.Claude.desktop";
          "x-scheme-handler/claude-cli" = "claude-code-url-handler.desktop";
        };
    };
}

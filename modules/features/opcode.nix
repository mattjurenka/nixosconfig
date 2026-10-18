# opcode (winfunc/opcode, formerly Claudia): a Tauri GUI around the Claude Code
# CLI -- session browser, custom agents, usage analytics, MCP management. It
# spawns `claude` itself and reads ~/.claude, so it rides the same subscription
# login as the terminal and needs no API key.
#
# Here to be tried rather than relied on. Upstream's newest release is v0.2.0
# from 2025-08-31, thirteen months behind its own main branch (last commit
# 2026-09-18) and behind a CLI that has changed a great deal since, so expect
# parts of it to be wrong about what Claude Code does now. If it earns its
# keep, the next step is building main from source, which means dealing with
# its bun lockfile; that is why this takes the prebuilt .deb instead.
{ ... }: {
  flake.nixosModules.opcode = { pkgs, lib, ... }:
    let
      opcode = pkgs.stdenv.mkDerivation (finalAttrs: {
        pname = "opcode";
        version = "0.2.0";

        src = pkgs.fetchurl {
          url = "https://github.com/winfunc/opcode/releases/download/v${finalAttrs.version}/opcode_v${finalAttrs.version}_linux_x86_64.deb";
          hash = "sha256-b7Eyddbm1vMHbGN7O55yFkzMlhHHjkrFTYmySEx9KgI=";
        };

        nativeBuildInputs = with pkgs; [
          dpkg
          autoPatchelfHook
          makeWrapper
          wrapGAppsHook3
        ];

        # A Tauri v2 app: a small Rust binary rendering its UI in WebKitGTK,
        # rather than an Electron bundle carrying its own browser.
        buildInputs = with pkgs; [
          webkitgtk_4_1
          gtk3
          glib
          cairo
          pango
          gdk-pixbuf
          libsoup_3
          openssl
          librsvg
          libayatana-appindicator
        ];

        dontConfigure = true;
        dontBuild = true;
        # wrapGAppsHook3's own wrapper would fight the one in postFixup.
        dontWrapGApps = true;

        unpackPhase = ''
          runHook preUnpack
          dpkg-deb --fsys-tarfile "$src" | tar --extract --file - --no-same-permissions
          runHook postUnpack
        '';

        installPhase = ''
          runHook preInstall
          install -Dm755 usr/bin/opcode "$out/lib/opcode/opcode"
          cp -a usr/share "$out/share"
          substituteInPlace "$out/share/applications/"*.desktop \
            --replace-fail "Exec=opcode" "Exec=$out/bin/opcode"
          runHook postInstall
        '';

        preFixup = ''
          gappsWrapperArgs+=(
            # The whole point of the app: it shells out to the CLI, and finds
            # it on its own PATH rather than the one niri gave the launcher.
            --prefix PATH : ${lib.makeBinPath (with pkgs; [ claude-code git ])}
            # WebKitGTK's DMA-BUF renderer paints nothing under a good many
            # Wayland compositors, which looks exactly like the app hanging on
            # a blank window. Cheap to set, and only costs a copy per frame.
            --set-default WEBKIT_DISABLE_DMABUF_RENDERER 1
          )
        '';

        postFixup = ''
          makeWrapper "$out/lib/opcode/opcode" "$out/bin/opcode" \
            "''${gappsWrapperArgs[@]}"
        '';

        meta = {
          description = "GUI and toolkit for Claude Code";
          homepage = "https://github.com/winfunc/opcode";
          license = lib.licenses.agpl3Only;
          mainProgram = "opcode";
          platforms = [ "x86_64-linux" ];
          sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        };
      });
    in
    {
      environment.systemPackages = [ opcode ];
    };
}

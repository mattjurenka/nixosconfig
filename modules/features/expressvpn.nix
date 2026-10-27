# ExpressVPN: the current universal Linux app (GUI, `expressvpn` CLI and
# daemon), and the Chromium extension that drives it.
#
# nixpkgs still ships 3.52, the retired CLI-only client. Its daemon hung at
# "Connecting..." on 2026-10-24 after pointing /etc/resolv.conf at the
# tunnel's resolver, which took the laptop's DNS with it, and the extension
# refuses it as out of date. ./expressvpn/_package.nix and _service.nix are
# NixOS/nixpkgs#561743 at d1c60789, which moves to 14.2.1; once that merges,
# delete both, the disabledModules line and the overlay.
#
# First use is `expressvpn login` (or sign in from the GUI) with the
# activation code from expressvpn.com/setup.
{ ... }: {
  flake.modules.nixos.expressvpn = { pkgs, ... }:
    let
      # The extension is a remote control: it drives the daemon through
      # browser_helper over native messaging. The app's installer fills in
      # the manifest's REPLACE_PATH; here it is the wrapper script, which sets
      # the brand variable the helper needs and execs it through
      # $out/bin/browser_helper, i.e. from /opt/expressvpn/bin, the only place
      # the daemon accepts clients from.
      chromeHelperManifest = pkgs.runCommand "expressvpn-chrome-helper-manifest" { } ''
        substitute ${pkgs.expressvpn}/share/chrome.com.expressvpn.helper.json $out \
          --replace-fail REPLACE_PATH ${pkgs.expressvpn}/share/browser_helper_wrapper.sh
      '';
    in
    {
      disabledModules = [ "services/networking/expressvpn.nix" ];
      imports = [ ./expressvpn/_service.nix ];
      nixpkgs.overlays = [
        (final: _: { expressvpn = final.callPackage ./expressvpn/_package.nix { }; })
      ];

      services.expressvpn = {
        enable = true;
        users = [ "matthew" ];
      };

      # The NixOS firewall's strict reverse-path check drops replies that come
      # back on the tunnel when the route to their source points out the
      # physical interface, which looks like "connected, but nothing loads".
      # Loose still drops packets from addresses with no route at all.
      networking.firewall.checkReversePath = "loose";

      # Chromium reads system-wide native messaging hosts from here.
      environment.etc."chromium/native-messaging-hosts/com.expressvpn.helper.json".source =
        chromeHelperManifest;

      # Merges with the rest of the list in matthew-home.nix.
      home-manager.users.matthew.programs.chromium.extensions = [
        { id = "fgddmllnllkalaagkghckoinaemmogpe"; } # ExpressVPN
      ];
    };
}

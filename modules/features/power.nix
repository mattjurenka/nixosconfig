# Power profiles and battery readings.
#
# power-profiles-daemon is what `powerprofilesctl` and the bar switch between
# performance and balanced; upower is what reports the battery -- of the
# machine and, with the Bluetooth settings in bluetooth.nix, of a headset.
#
# What is deliberately not here: omni-laptop's ac-power-switch service, which
# picks a profile from whether the charger is in. That is a laptop with a
# charger-dependent Wi-Fi quirk, not a capability every host shares.
{ ... }: {
  flake.modules.nixos.power = {
    services.power-profiles-daemon.enable = true;
    services.upower.enable = true;
  };
}

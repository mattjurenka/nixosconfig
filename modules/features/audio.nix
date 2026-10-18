# Sound, including over Bluetooth.
#
# PipeWire rather than PulseAudio because the Bluetooth backend is the part
# that matters here: the `bluetooth.nix` settings ask for A2DP sink and source,
# and wireplumber is what actually routes a headset once it connects.
{ ... }: {
  flake.modules.nixos.audio = {
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
      wireplumber.enable = true;
    };
  };
}

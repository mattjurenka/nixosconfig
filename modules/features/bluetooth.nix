# Bluetooth, tuned for headsets and for the bar showing their battery.
{ ... }: {
  flake.modules.nixos.bluetooth = {
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings = {
        General = {
          # Enables A2DP Sink, Media, and lower-level profiles
          Enable = "Source,Sink,Media,Socket";
          # Speeds up connection handshakes
          FastConnectable = true;
          # Keeps battery status updating accurately in Noctalia
          Experimental = true;
          AutoConnect = true;
          JustWorksRepairing = "always";
        };
        Policy = {
          AutoEnable = true;
        };
      };
    };
  };
}

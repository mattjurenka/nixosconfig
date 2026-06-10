{ self, inputs, ... }: {
  flake.nixosModules.myMachineHardware = { config, lib, pkgs, modulesPath, ... }: {
    imports =
      [ (modulesPath + "/profiles/qemu-guest.nix")
      ];

    boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "ehci_pci" "sd_mod" "sr_mod" ];
    boot.initrd.kernelModules = [ ];
    boot.kernelModules = [ "kvm-intel" ];
    boot.extraModulePackages = [ ];

    fileSystems."/" =
      { device = "/dev/disk/by-uuid/d55cc495-497a-4a48-854c-fc4735f19528";
        fsType = "ext4";
      };

    fileSystems."/boot" =
      { device = "/dev/disk/by-uuid/D751-D51C";
        fsType = "vfat";
        options = [ "fmask=0022" "dmask=0022" ];
      };

    swapDevices =
      [ { device = "/dev/disk/by-uuid/15203390-4b5a-4983-b51f-b5e7171beb05"; }
      ];

    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  };
}

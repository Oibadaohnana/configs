{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "thunderbolt" "usb_storage" "uas" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/1b8f61b8-0417-45d2-b60d-d643d9cd4cf8";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/C3F4-6352";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };
 
  swapDevices = [ ];

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.wlp1s0.useDHCP = lib.mkDefault true;

  # The Pixart i2c-HID touchpad (PIXA3854) raises ~140 interrupts/second even
  # when nobody is touching it, and it is armed as a wakeup source by default.
  # Under s2idle that means Meta+Shift+S suspends and the very next touchpad
  # interrupt resumes the machine a fraction of a second later -- the wake lands
  # on IRQ 7 (pinctrl_amd), the AMD GPIO controller the touchpad hangs off.
  # Take the touchpad out of the wakeup set; the keyboard (i8042), power button
  # (PNP0C0C) and lid (PNP0C0D) stay enabled, so there is still plenty to wake
  # the laptop with. Matches "bind" as well as "add" because power/wakeup only
  # shows up once i2c_hid_acpi has probed the device.
  services.udev.extraRules = ''
    ACTION=="add|bind", SUBSYSTEM=="i2c", ATTR{name}=="PIXA3854:00", ATTR{power/wakeup}="disabled"
  '';

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}

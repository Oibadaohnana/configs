{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "thunderbolt" "usb_storage" "uas" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # HDMI-A-1 shows "no signal" until its input button is pressed by hand. The
  # monitor doesn't assert hot-plug detect while it's idling on another input,
  # so amdgpu probes the connector as disconnected at boot and never drives it
  # -- and a connector the kernel thinks is absent is one no compositor can turn
  # on, which is why neither GDM nor Hyprland can fix this from userspace.
  #
  # The trailing `e` forces the connector enabled regardless of what detection
  # says. The mode is spelled out rather than left to EDID because a monitor
  # that isn't answering hot-plug detect isn't answering EDID reads either, and
  # the no-EDID fallback is 1024x768. 1280x720@60 matches the HDMI-A-1 rule in
  # configs/hyprland.lua.
  boot.kernelParams = [ "video=HDMI-A-1:1280x720@60e" ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/d54c4436-4d06-4beb-a626-03f0f479a9a4";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/40E9-F9FC";
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

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}

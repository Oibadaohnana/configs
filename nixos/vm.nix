{ config, pkgs, ... }:
{
  # Basic host setup for running Windows 11 in QEMU/KVM via libvirt.
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      swtpm.enable = true;
    };
  };

  programs.virt-manager.enable = true;
  virtualisation.spiceUSBRedirection.enable = true;

  environment.systemPackages = with pkgs; [
    virt-manager
    virt-viewer
    spice-gtk
    swtpm
  ];

  # Allow the primary user to manage VMs without sudo.
  users.users.benji.extraGroups = [ "libvirtd" "kvm" ];
}

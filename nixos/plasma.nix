{ config, pkgs, ... }:

{
  # Plasma 6 desktop environment
  services.desktopManager.plasma6.enable = true;
  environment.plasma6.excludePackages = with pkgs.kdePackages; [
    kate
  ];

  # Plasma's own portal backend (for file pickers, screen sharing, etc.)
  xdg.portal.extraPortals = [
    pkgs.kdePackages.xdg-desktop-portal-kde
  ];
}

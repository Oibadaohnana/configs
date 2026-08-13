{ config, pkgs, ... }:

{
  programs.hyprland.enable = true;
  programs.hyprland.withUWSM = false;

  xdg.portal.extraPortals = [
    pkgs.xdg-desktop-portal-hyprland
    pkgs.xdg-desktop-portal-gtk
  ];

  environment.systemPackages = with pkgs; [
    hyprlock
    wlogout
    hyprpaper
    rofi
    waybar
    mako
    grim
    slurp
    wlsunset
    brightnessctl
    cliphist
    wdisplays
    playerctl
    libnotify
    pulseaudio
  ];
}

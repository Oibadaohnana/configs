{ config, pkgs, ... }:

{
  programs.sway = {
    enable = true;
    extraPackages = with pkgs; [
      grim
      wofi
      slurp
      waybar
      wl-clipboard
      mako
      wdisplays
      wmenu
      swayidle
      swaylock
    ];
    wrapperFeatures = {
      base = true;
      gtk = true;
    };
  };
  environment.variables = {
    GTK_ICON_THEME = "Papirus-Dark";
  };
}

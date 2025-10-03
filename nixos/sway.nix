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

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    MOZ_ENABLE_WAYLAND = "1";
    QT_QPA_PLATFORM = "wayland";
    XDG_SESSION_TYPE = "wayland";
  };

  environment.variables = {
    GTK_ICON_THEME = "Papirus-Dark";
  };
}

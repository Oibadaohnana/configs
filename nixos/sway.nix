{ config, pkgs, ... }:

{
  # Enable necessary services

  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;
    extraOptions = ["--unsupported-gpu"];
    extraConfigFile = "/home/benji/nixcfg/configs/configs/swayconfig";
  };

  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.sway}/bin/sway --unsupported-gpu";
        user = "benji";
      };
    };
  };

  
  # Enable PipeWire for audio and screen sharing
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    jack.enable = false;
  };

  # Input device support (seatd is simpler than elogind for some setups)
  services.seatd.enable = true;

  # D-Bus is needed for a number of Wayland utilities
  services.dbus.enable = true;

  # Environment/system packages used with sway
  environment.systemPackages = with pkgs; [
    sway
    foot             # Wayland terminal
    wl-clipboard     # clipboard utilities (wl-copy/wl-paste)
    mako             # notification daemon
    grim
    slurp       # screenshots
    brightnessctl    # screen brightness
    networkmanagerapplet
    swaylock         # lock screen
    swayidle         # idle management
  ];

  # Set default shell if needed
  # users.users.your-username.shell = pkgs.zsh;


  users.users.benji = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
  };
}

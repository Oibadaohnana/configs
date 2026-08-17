{ config, pkgs, ... }:

{
  # GDM instead of SDDM: SDDM's wayland greeter runs under a bare weston kiosk
  # shell, which draws no cursor because libwayland-cursor only looks in
  # /usr/share/icons and friends -- paths that don't exist on NixOS. GDM's
  # greeter is mutter, which resolves its own cursor theme and handles the
  # touchpad through libinput directly.
  services.displayManager.gdm.enable = true;
  services.displayManager.defaultSession = "hyprland";
  # Enable experimental features (optional)
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  services.xserver.videoDrivers = ["amdgpu"];

  nixpkgs.config.allowUnfree = true;

  services.power-profiles-daemon.enable = true;
  
    services.logind.settings = {
      Login = {
        IdleAction = "ignore";
        IdleActionSec = "0";
      };
    };
  services.upower.enable = true;
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;
    shellAliases = {
      ll = "ls -l";
      edit = "sudo -e";
      update = "sudo nixos-rebuild switch";
    };

    histSize = 10000;
    histFile = "$HOME/.zsh_history";
    setOptions = [
      "HIST_IGNORE_ALL_DUPS"
    ];
  };

  # Enable GameMode daemon + CLI wrapper for Steam launch options.
  programs.gamemode.enable = true;
  programs.steam.enable = true;

  # System packages
  environment.systemPackages = with pkgs; [
    firefox
    adwaita-icon-theme
    kdePackages.dolphin
    kdePackages.kcalc
    kdePackages.kcharselect
    wayland-utils
    wl-clipboard
    git
    fd
    spotify
    telegram-desktop
    mpv
    vlc
    libreoffice-fresh
    mumble
    beyond-all-reason
    nodejs_24
    electron
    discord
    thunderbird
    signal-desktop
    kitty
    btop
    obs-studio
    syncthing
    onedrive
    blender
    numbat
    pavucontrol
    gamemode
    onedrive
    hplip
    unrar
    claude-code
    reaper
    p7zip
    qpwgraph
  ];

  programs.appimage = {
  enable = true;
  binfmt = true;
  };

  # Enable external storage, SD cards, and phone support
  services.gvfs.enable = true;
  services.udisks2.enable = true;
  services.usbmuxd.enable = true;

  # Audio configuration: PipeWire + WirePlumber
  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
  services.pipewire.wireplumber.enable = true;

  # Enable bluetooth
  services.blueman.enable = true;
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;
  hardware.bluetooth.settings = {
    General.Experimental = true;
    Policy.AutoEnable = true;
  };

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    ELECTRON_OZONE_PLATFORM_HINT = "wayland";
    XCURSOR_THEME = "Adwaita";
    XCURSOR_SIZE = "24";
  };
  xdg.portal.enable = true;

  # System basics
  time.timeZone = "Europe/Berlin";
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "de_DE.UTF-8";
    LC_IDENTIFICATION = "de_DE.UTF-8";
    LC_MEASUREMENT = "de_DE.UTF-8";
    LC_MONETARY = "de_DE.UTF-8";
    LC_NAME = "de_DE.UTF-8";
    LC_NUMERIC = "de_DE.UTF-8";
    LC_PAPER = "de_DE.UTF-8";
    LC_TELEPHONE = "de_DE.UTF-8";
    LC_TIME = "de_DE.UTF-8";
  };
  console.keyMap = "de";

  services.printing = {
  enable = true;
  drivers = [ pkgs.hplip ];
};

services.avahi = {
  enable = true;
  nssmdns4 = true;
  openFirewall = true;
};

  networking.networkmanager.enable = true;

  # User setup
  users.users.benji = {
    isNormalUser = true;
    description = "Benjamin Wüst";
    shell = pkgs.zsh;
    extraGroups = [ "wheel" "networkmanager" "plugdev" "adbusers" ];
  };

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # System version
  system.stateVersion = "25.05";

  
}

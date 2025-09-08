{ config, pkgs, ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "Bdawg";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/Berlin";
  i18n.defaultLocale = "en_US.UTF-8";

  # Locale Settings
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

  services.printing.enable = true;
  


  # Sound via Pipewire
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
  services.blueman.enable = true;
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Experimental = true;
        #FastConnectable = true;
      };
      Policy = {
        AutoEnable = true;
    };
  };
};
  
  # User configuration
  users.users.benji = {
    isNormalUser = true;
    description = "Benjamin Wüst";
    extraGroups = [ "networkmanager" "wheel"];
  };

  programs.firefox.enable = true;

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    git
    firefox
    fd
    spotify
    steam
    vscode
    rofi-wayland
    foot
    kitty
    sway
    swaybg
    wayland-utils
    wdisplays
    networkmanager
    xwayland
    vim
    telegram-desktop
    vlc
    grim
    slurp
    xfce.thunar
    nomacs
    bluetuith
    gamescope
    libreoffice
  ];

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
        vulkan-loader
        vulkan-validation-layers
        vulkan-extension-layer
        vulkan-tools
        wayland
    ];
  };

  services.openssh.enable = true;

  system.stateVersion = "25.05"; # Your NixOS release version
}

{ config, pkgs, ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  services.xserver.enable = true;
  services.desktopManager.plasma6.enable = true;
  programs.sway.enable = true;
  services.displayManager.sddm.enable = true;
  services.displayManager.defaultSession = "plasma";  # or "sway"

  services.onedrive.enable = true;


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
    foot
    kitty
    fd
    spotify
    steam
    vscode
    networkmanager
    vim
    telegram-desktop
    vlc
    grim
    slurp
    nomacs
    gamescope
    libreoffice
  ] ++ (with pkgs.kdePackages; [
    dolphin
    konsole  # explicitly from kdePackages now
  ]);

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    MOZ_ENABLE_WAYLAND = "1";
    QT_QPA_PLATFORM = "wayland";
  };
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
        vulkan-loader
        vulkan-validation-layers
        vulkan-extension-layer
        vulkan-tools
        wayland
        mesa
        vaapiVdpau
        libvdpau-va-gl
    ];
  };
  #services.openssh.enable = true;

  system.stateVersion = "25.05"; # Your NixOS release version
}

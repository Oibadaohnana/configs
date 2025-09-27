{ config, pkgs, ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  #services.desktopManager.plasma6.enable = true;
  #services.displayManager.defaultSession = "sway";  # or "plasma"
  #services.displayManager.sddm.enable = true;
  programs.sway.enable = true;
  services.greetd.enable = true;
  services.greetd.settings = {
    default_session = {
      command = "${pkgs.sway}/bin/sway";
      user = "benji";
    };
  };
  services.onedrive.enable = true;
  systemd.user.services.onedrive.enable = false;
  systemd.user.services."onedrive-launcher".enable = false;
  #onesync to sync
  

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
  services.pipewire.wireplumber.enable = true;
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


  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    firefox-bin
    git
    firefox
    kitty
    fd
    spotify
    steam
    networkmanager
    vim
    telegram-desktop
    vlc
    grim
    wofi
    slurp
    nomacs
    gamescope
    libreoffice
    pavucontrol
    xfce.thunar
    bluetuith
    gvfs
    libappindicator
    xwayland
    mumble
    waybar
    wl-clipboard
    mako
    wdisplays
    libnotify
    python3
    uv
    beyond-all-reason
    nodejs_24
    electron
    discord
  ];

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    MOZ_ENABLE_WAYLAND = "1";
    QT_QPA_PLATFORM = "wayland";
    XDG_SESSION_TYPE="wayland";
  };

  environment.variables = {
    GTK_ICON_THEME = "Papirus-Dark";
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

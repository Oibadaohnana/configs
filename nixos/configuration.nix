{ config, pkgs, ... }:

{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    stdenv.cc.cc glibc zlib curl openssl icu
  ];
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

  #Phone Mount
  services.gvfs.enable = true;
  services.udisks2.enable = true;
  services.usbmuxd.enable = true;

  programs.adb.enable = true;

  #Firmware Updater
  services.fwupd.enable = true;

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
  
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  
  services.dbus.enable = true;
  xdg.portal.enable = true;
  xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

  networking.hostName = "Bdawg";
  networking.networkmanager.enable = true;

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

  services.printing.enable = true;

  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    extraConfig.pipewire = {
    "bluez-monitor" = {
      "properties" = {
        # Prevents PipeWire from auto-switching to headset (HSP/HFP) mode
        "bluez5.auto-switch-to-hsp" = false;
        # Optional: disables HFP completely so it never even shows up
        "bluez5.headset-roles" = "[ none ]";
        };
      };
    }; 
  };
  programs.gamemode.enable = true;
  services.pipewire.wireplumber.enable = true;
  services.blueman.enable = true;
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Experimental = true;
      };
      Policy = {
        AutoEnable = true;
      };
    };
  };

  users.users.benji = {
    isNormalUser = true;
    description = "Benjamin Wüst";
    shell = pkgs.zsh;
    extraGroups = [ "networkmanager" "wheel" "plugdev" "adbusers" "gamemode"];
  };
  
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    pulseaudio
    firefox-bin
    git
    firefox
    fd
    spotify
    steam
    networkmanager
    vim
    telegram-desktop
    mpv
    vlc
    gamescope
    libreoffice-fresh
    pavucontrol
    xfce.thunar
    xfce.thunar-volman
    xfce.thunar-archive-plugin
    xfce.xfconf
    bluetuith
    gvfs
    libappindicator
    xwayland
    mumble
    libnotify
    uv
    beyond-all-reason
    nodejs_24
    electron
    discord
    brightnessctl
    wlsunset
    libmtp
    simple-mtpfs
    thunderbird
    signal-desktop-bin
    kitty
    btop
    obs-studio
    unzip
    syncthing
    blender
    bibata-cursors
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
      mesa
      mesa.opencl
      vaapiVdpau
      libvdpau-va-gl
    ];
  };
  environment.sessionVariables = {
    QT_QPA_PLATFORM = "wayland";
    QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
    XDG_CURRENT_DESKTOP = "sway";
    XDG_SESSION_TYPE = "wayland";
    NIXOS_OZONE_WL = "1";
    ELECTRON_OZONE_PLATFORM_HINT = "wayland";
  };
  system.stateVersion = "25.05";
}

{ config, lib, pkgs, ... }:

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
  
  networking.firewall.allowedTCPPorts = [ 8787 ];	
  # System packages
  environment.systemPackages = with pkgs; [
    firefox
    adwaita-icon-theme
    # Terminal editor. Nano-style keys (ctrl+s save, ctrl+q quit, ctrl+z undo)
    # but with syntax highlighting and mouse support. Set as EDITOR below.
    micro
    kdePackages.dolphin
    kdePackages.kcalc
    kdePackages.kcharselect
    # What QT_QPA_PLATFORMTHEME = "kde" above actually loads. plasma.nix pulls
    # these in on benji-framework via plasma6, but benji-desktop imports
    # dolphin without Plasma, so name them here to keep both hosts readable.
    kdePackages.plasma-integration
    kdePackages.breeze
    wayland-utils
    wl-clipboard
    git
    spotify
    telegram-desktop
    mpv
    vlc
    libreoffice-fresh
    mumble
    beyond-all-reason
    discord
    thunderbird
    signal-desktop
    kitty
    btop
    obs-studio
    syncthing
    onedrive
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
    kdePackages.kdenlive
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
    # re-pair reset speakers without a confirm prompt
    General.JustWorksRepairing = "always";
    Policy.AutoEnable = true;
  };

  # Auto-trust paired devices. Untrusted -> bluetoothd asks an agent to
  # authorize every service connect; pairing via bluetoothctl never sets it.
  # bluez has no auto-trust setting, hence the watcher.
  systemd.services.bluetooth-auto-trust = {
    description = "Trust paired Bluetooth devices";
    after = [ "bluetooth.service" ];
    bindsTo = [ "bluetooth.service" ];
    wantedBy = [ "bluetooth.target" ];
    path = [ pkgs.bluez pkgs.dbus pkgs.gawk pkgs.gnugrep ];
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
    script = ''
      trust_all() {
        bluetoothctl devices Paired | awk '{print $2}' | while read -r mac; do
          bluetoothctl info "$mac" | grep -q "Trusted: yes" || bluetoothctl trust "$mac"
        done
      }
      trust_all
      dbus-monitor --system \
        "type='signal',interface='org.freedesktop.DBus.ObjectManager',member='InterfacesAdded'" \
        "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',arg0='org.bluez.Device1'" \
      | while read -r line; do
          case "$line" in
            *InterfacesAdded*|*Paired*) trust_all ;;
          esac
        done
    '';
  };

  # Keep Bluetooth headsets pinned to A2DP (AAC/SBC-XQ, stereo 48kHz).
  # Classic Bluetooth can't do A2DP playback and the mic at once, so any app
  # that opens the headset mic drags the card onto HSP/HFP -- mono 16kHz.
  # Dota 2 (SDL) grabs the default source at launch even with voice chat unused,
  # which is what was wrecking game audio. Trade-off: the headset mic no longer
  # works system-wide. Re-enable it for a call with:
  #   wpctl set-profile <card-id> headset-head-unit
  services.pipewire.wireplumber.extraConfig."51-bluez-no-autoswitch" = {
    "wireplumber.settings" = {
      "bluetooth.autoswitch-to-headset-profile" = false;
    };
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
    # Under Hyprland there is no Plasma session to hand Qt apps a color scheme,
    # so Dolphin and friends fall back to Qt's built-in light palette: black
    # text on the dark Breeze scheme already sitting in ~/.config/kdeglobals,
    # which is unreadable. Pointing Qt at the KDE platform theme
    # (plasma-integration) makes it read kdeglobals again.
    QT_QPA_PLATFORMTHEME = "kde";
    # What git, systemctl edit, crontab and friends open. VISUAL as well as
    # EDITOR: tools that distinguish them treat VISUAL as the full-screen one,
    # and falling back to a line editor here would be a downgrade.
    EDITOR = "micro";
    VISUAL = "micro";
    # micro forces tcell down to 256 colours unless this is set, which would
    # flatten the gruvbox-dark-hard scheme's RGB into near-identical greys.
    MICRO_TRUECOLOR = "1";
  };
  xdg.portal.enable = true;

  # Same family of problem as QT_QPA_PLATFORMTHEME above: a KDE app in a session
  # that isn't Plasma. Without this file KDE's application index comes out empty
  # and Dolphin cannot open anything by double-click -- the file itself explains
  # the mechanism. It goes through environment.etc rather than symlinks.sh
  # because only XDG_CONFIG_DIRS entries are searched for the base menu, and
  # /etc/xdg is the writable-by-Nix one of those.
  environment.etc."xdg/menus/applications.menu".source =
    ../configs/menus/applications.menu;

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

  # Disable WiFi powersave: the MT7922 sleeps between packets, which adds
  # ~3ms latency and 4x jitter (measured 1.9ms/1.3 awake vs 5.2ms/5.2 asleep).
  # NM's own default enables it, so this must be set explicitly.
  networking.networkmanager.wifi.powersave = false;

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

  # sshd is defined but not started at boot -- the sshon/sshoff aliases bring it
  # up and down. openFirewall keeps 22 open either way; with the listener down
  # the port just refuses, so nothing to toggle there.
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "benji" ];
      MaxAuthTries = 3;
      PerSourcePenalties = "crash:3600s authfail:3600s max:86400s";
    };
  };
  systemd.services.sshd.wantedBy = lib.mkForce [ ];
  
}

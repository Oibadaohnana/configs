{ config, pkgs, lib, ... }:

# X11 counterpart to hyprland.nix. Nothing here is imported by flake.nix yet --
# add ./i3.nix to a host's module list (and drop ./hyprland.nix, or keep both
# and pick the session at the GDM greeter) when you want to run it.
#
# The session it installs is called "none+i3", so switching the default over
# means setting services.displayManager.defaultSession = "none+i3" in
# configuration.nix, which currently says "hyprland".

{
  services.xserver.enable = true;

  services.xserver.windowManager.i3 = {
    enable = true;
    # i3 4.22 merged i3-gaps, so plain i3 already understands the `gaps`
    # statements in configs/i3config.
    package = pkgs.i3;
    # Only i3lock: this list replaces the module default (i3status, dmenu),
    # and polybar and rofi already cover what those two were for.
    extraPackages = with pkgs; [ i3lock ];
  };

  # Hyprland reads kb_layout/kb_options itself; on X11 the server owns them.
  # Duplicated by the setxkbmap line in configs/i3config so the layout is right
  # even when X was started with different defaults.
  services.xserver.xkb = {
    layout = "de";
    options = "caps:super";
  };

  # hyprland.lua's input block. On X11 these are libinput's, not the WM's.
  services.libinput = {
    enable = true;

    touchpad = {
      naturalScrolling = false;     # natural_scroll = false
      tapping = true;               # tap_to_click = true
      middleEmulation = true;       # middle_button_emulation = true
      # touchpad.scroll_factor = 0.5 has no libinput equivalent -- libinput
      # exposes no scroll-speed multiplier at all, so this one is simply lost.
    };

    mouse = {
      accelProfile = "flat";        # accel_profile = "flat"
      accelSpeed = "0";             # sensitivity = 0
    };
  };

  # misc.vrr = 3 -- adaptive sync for fullscreen apps only. On X11 that is an
  # amdgpu DDX option rather than anything the WM can set. "TearFree" is left
  # off deliberately: it is the opposite of general.allow_tearing = true, and
  # picom's vsync = false (configs/picom.conf) is the tearing half of the same
  # trade -- lower input latency for a visible tear line.
  services.xserver.deviceSection = ''
    Option "VariableRefresh" "true"
    Option "TearFree" "false"
  '';

  environment.systemPackages = with pkgs; [
    # --- Session bits, replacing the hypr* family -------------------------
    i3lock          # hyprlock
    xautolock       # hypridle's idle -> suspend timer
    xss-lock        # hypridle's lock-before-sleep half
    feh             # hyprpaper
    rofi            # same package hyprland.nix installs -- rofi is X11-native
    # waybar -- see configs/polybarconfig/config.ini. i3Support is off by
    # default in nixpkgs, and without it internal/i3 does not exist at all;
    # pulseSupport likewise gates internal/pulseaudio.
    (polybar.override { i3Support = true; pulseSupport = true; })
    dunst           # mako
    picom           # hyprland's own decoration.blur / inactive_opacity

    # --- Screenshot: grim + slurp + wl-copy ------------------------------
    maim            # grim
    slop            # slurp
    xclip           # wl-copy

    # --- Clipboard history: wl-paste --watch cliphist ---------------------
    haskellPackages.greenclip

    # --- Display arrangement: wdisplays -----------------------------------
    arandr
    xorg.xrandr

    # --- Window/pointer tools the scripts lean on -------------------------
    # No xdotool or wmctrl: every window operation here goes through i3's own
    # IPC (i3-msg), which is the only thing that can focus across workspaces.
    xorg.xkill      # hyprctl kill
    xorg.xsetroot   # misc.background_color
    xorg.xrdb       # Xft.dpi, standing in for per-output scale
    xorg.xset       # DPMS, i.e. after_sleep_cmd
    jq              # i3_cycle.sh / i3_maximize.sh parse the i3 IPC tree

    # --- Unchanged from hyprland.nix; none of these are Wayland-only ------
    brightnessctl
    playerctl
    libnotify
    pulseaudio
  ];

  # NIXOS_OZONE_WL / ELECTRON_OZONE_PLATFORM_HINT in configuration.nix push
  # Electron apps onto Wayland, which under X11 makes them fall back noisily.
  # Unset rather than overridden, so the same configuration.nix serves both.
  environment.sessionVariables = {
    NIXOS_OZONE_WL = lib.mkForce "";
    ELECTRON_OZONE_PLATFORM_HINT = lib.mkForce "x11";

    # The GTK/Qt half of Xft.dpi 192 (configs/i3config), standing in for
    # Hyprland's per-output scale = 2. Integer-only on GTK3: 2 is the one
    # usable value, and the framework's 1.5 cannot be expressed here at all.
    GDK_SCALE = "2";
    GDK_DPI_SCALE = "0.5";
    QT_AUTO_SCREEN_SCALE_FACTOR = "0";
    QT_SCALE_FACTOR = "2";
  };

  # xdg-desktop-portal-hyprland has no X11 counterpart; the GTK portal alone
  # covers file pickers and screen sharing under i3.
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };
}

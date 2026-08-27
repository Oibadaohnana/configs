-- Hyprland configuration
-- Ported from the legacy hyprland.conf format (deprecated as of Hyprland 0.56,
-- removed in 0.57). See https://wiki.hypr.land/Configuring/Start/

----------------------------------------
-- Variables
----------------------------------------
local mod  = "SUPER"
local term = "kitty"
local menu = "rofi -show drun"

----------------------------------------
-- Monitors
----------------------------------------
-- Desktop
hl.monitor({ output = "DP-3", mode = "2560x1440@180", position = "0x0", scale = 2 })

-- Secondary display always auto-enables at a fixed 720p, not its native
-- resolution. Named rules take precedence over the wildcard rule below.
hl.monitor({ output = "HDMI-A-1", mode = "1280x720@60", position = "auto", scale = 1 })

-- Any other/unlisted external display auto-enables at its preferred
-- resolution whenever it's plugged in.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

-- Workspace 4 always lives on the secondary screen
hl.workspace_rule({ workspace = "4", monitor = "HDMI-A-1" })

-- Laptop (uncomment when on framework)
-- hl.monitor({ output = "DP-10", mode = "2560x1440@144", position = "1128x0", scale = 1 })
-- hl.monitor({ output = "DP-11", mode = "2560x1440@144", position = "1128x0", scale = 1 })
-- hl.monitor({ output = "DP-2",  mode = "2560x1440@144", position = "0x0",    scale = 1 })
-- hl.monitor({ output = "eDP-1", mode = "preferred",     position = "0x0",    scale = 1.5 })

----------------------------------------
-- Saved monitor on/off state
----------------------------------------
-- ~/nixcfg/scripts/monitors.sh records which outputs were switched off, one
-- name per line, and this reads them back so the choice survives a logout.
-- Read from Lua rather than shelled out to, so a saved-off output never
-- flashes on before being switched off again.
--
-- The file deliberately lives outside this repo: it is per-machine state, and
-- the desktop and the framework have different output names.
local disabled_monitors_file =
    (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state"))
    .. "/hypr/disabled-monitors"

local function saved_disabled_outputs()
    local outputs = {}
    local f = io.open(disabled_monitors_file, "r")
    if not f then return outputs end
    for line in f:lines() do
        local output = line:match("^%s*(.-)%s*$")
        if output ~= "" and output:sub(1, 1) ~= "#" then
            outputs[#outputs + 1] = output
        end
    end
    f:close()
    return outputs
end

-- hl.get_monitor() returns nil for an output that is disabled or absent, so
-- #hl.get_monitors() counts the *enabled* ones. Never switch off the last of
-- them: a stale entry here (the laptop panel saved as off, then booted
-- undocked) would otherwise leave a black screen with no way back.
--
-- Every saved output is re-checked on each call, not just a newly added one,
-- because at login the monitors arrive one at a time: the first one cannot be
-- switched off while it is alone, and only once a second arrives does the
-- saved "off" for the first become safe to apply.
local function apply_saved_monitor_state()
    for _, output in ipairs(saved_disabled_outputs()) do
        if hl.get_monitor(output) and #hl.get_monitors() > 1 then
            hl.monitor({ output = output, disabled = true })
        end
    end
end

apply_saved_monitor_state()

-- A monitor plugged in later is auto-enabled by the wildcard rule above, which
-- would undo a saved "off", so re-apply whenever one appears. Both events also
-- poke waybar, whose custom/monitors tile would otherwise sit stale until its
-- next poll. The signal number matches WAYBAR_SIGNAL in monitors.sh.
--
-- The pinned left-to-right order is re-applied by the script rather than here:
-- placing the outputs edge to edge means measuring the logical size of each
-- one, which it already parses out of hyprctl. It also repairs an overlap even
-- when nothing is pinned -- Hyprland stacks two outputs on the same spot
-- without a word of complaint, so nothing else would ever notice.
--
-- The second of delay is not decoration: this event arrives before Hyprland
-- has finished placing the new output, and re-packing the row against a
-- half-settled layout is how an output ends up sitting on top of another.
hl.on("monitor.added", function()
    apply_saved_monitor_state()
    hl.exec_cmd("sleep 1 && ~/nixcfg/scripts/monitors.sh layout")
    hl.exec_cmd("pkill -RTMIN+8 waybar")
end)

hl.on("monitor.removed", function()
    hl.exec_cmd("sleep 1 && ~/nixcfg/scripts/monitors.sh layout")
    hl.exec_cmd("pkill -RTMIN+8 waybar")
end)

-- Reloading the config re-runs the wildcard rule at the top of this file, and
-- `position = "auto"` then re-packs the row in whatever order Hyprland fancies
-- -- throwing away the pinned arrangement. Nothing else notices, because the
-- result is a valid non-overlapping layout, just not the requested one. So put
-- it back every time the config is re-read.
hl.on("config.reloaded", function()
    hl.exec_cmd("sleep 1 && ~/nixcfg/scripts/monitors.sh layout")
end)

----------------------------------------
-- Input
----------------------------------------
hl.config({
    input = {
        kb_layout = "de",
        kb_options = "caps:super",
        sensitivity = 0,
        accel_profile = "flat",

        touchpad = {
            natural_scroll = false,
            tap_to_click = true,
            middle_button_emulation = true,
            scroll_factor = 0.5,
        },
    },

    cursor = {
        no_hardware_cursors = false,
    },
})

----------------------------------------
-- General / Appearance
----------------------------------------
hl.config({
    general = {
        gaps_in = 0,
        gaps_out = 0,
        border_size = 1,
        col = {
            active_border = "rgba(222222ff)",
            inactive_border = "rgba(222222ff)",
        },
        layout = "dwindle",

        -- Master switch for tearing. Nothing tears on its own: only windows
        -- carrying an `immediate` rule do, and only while fullscreen and alone
        -- on screen. Trades a visible tear line for lower input latency.
        allow_tearing = true,
    },

    decoration = {
        rounding = 0,
        active_opacity = 1.0,
        inactive_opacity = 0.9,
        blur = {
            enabled = true,
            size = 5,
            passes = 2,
        },
    },

    misc = {
        background_color = 0xFF000000,
        -- Adaptive sync. 3 = fullscreen_game: VRR engages only when the
        -- fullscreen app reports game content, so the desktop keeps a fixed
        -- refresh and only games get the variable one.
        vrr = 3,
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        force_default_wallpaper = 0,
    },

    ecosystem = {
        no_update_news = true,
        no_donation_nag = true,
    },

    animations = {
        enabled = false,
    },

    dwindle = {
        preserve_split = true,
    },

    -- Hands a fullscreen window's buffer straight to the display controller,
    -- skipping Hyprland's composite pass entirely. Off by default (0).
    -- 2 = auto, which scans out when it can and falls back when it can't.
    render = {
        direct_scanout = 2,
    },

    -- XWayland (Steam, Proton games, etc.) doesn't support fractional scaling.
    -- Without this, Hyprland GPU-upscales the whole surface, which is what
    -- causes the blurry/smeared look in Steam and games it launches.
    xwayland = {
        force_zero_scaling = true,
    },
})

----------------------------------------
-- Window rules
----------------------------------------
-- Steam games often resize themselves to screen size instead of properly
-- requesting fullscreen, so Hyprland treats them as a normal maximized window
-- and respects waybar's reserved space, leaving the bar visible. Force real
-- compositor fullscreen for Steam-launched games (class is always
-- "steam_app_<appid>") so they cover the bar like any other fullscreen window.
hl.window_rule({
    name = "steam-games-fullscreen",
    match = { initial_class = "^steam_app_\\d+$" },

    fullscreen = true,
    -- Tear rather than wait for vblank: lowest input latency in-game.
    immediate  = true,
})

----------------------------------------
-- Autostart
----------------------------------------
hl.on("hyprland.start", function()
    -- withUWSM=false: nothing activates graphical-session.target, which
    -- xdg-desktop-portal has as Requisite -- no portal, no OBS screen capture.
    -- Env push first; hyprland backend is ConditionEnvironment=WAYLAND_DISPLAY.
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP HYPRLAND_INSTANCE_SIGNATURE && systemctl --user start nixos-fake-graphical-session.target")
    hl.exec_cmd("waybar -c ~/nixcfg/configs/waybarconfig/config -s ~/nixcfg/configs/waybarconfig/style.css")
    hl.exec_cmd("mako")
    -- hl.exec_cmd("wlsunset -l 50.59 -L 8.69 -t 3000 -T 6500")
    hl.exec_cmd("hyprpaper")
    hl.exec_cmd("wl-paste --watch cliphist store")
    hl.exec_cmd("hypridle")
    -- Registers the BlueZ pairing/authorization agent. Without it, devices
    -- reconnecting at login are rejected outright ("Authentication attempt
    -- without agent") with no way to approve them.
    hl.exec_cmd("blueman-applet")
end)

----------------------------------------
-- Apps
----------------------------------------
hl.bind(mod .. " + RETURN", hl.dsp.exec_cmd(term))
hl.bind(mod .. " + F2",     hl.dsp.exec_cmd("firefox"))
hl.bind(mod .. " + F1",     hl.dsp.exec_cmd("pavucontrol"))
hl.bind(mod .. " + F3",     hl.dsp.exec_cmd("~/nixcfg/scripts/focus_or_launch.sh blueman-manager blueman-manager"))
hl.bind(mod .. " + F4",     hl.dsp.exec_cmd("wdisplays"))
-- Meta+P = Open the display layout/editing tool
hl.bind(mod .. " + P",      hl.dsp.exec_cmd("wdisplays"))
hl.bind(mod .. " + D",      hl.dsp.exec_cmd(menu))
-- Meta+V = Show Clipboard (matches Plasma)
hl.bind(mod .. " + V",      hl.dsp.exec_cmd("cliphist list | rofi -dmenu | cliphist decode | wl-copy"))
-- Meta+End = Toggle gaming display (matches Plasma)
-- Routed through monitors.sh rather than calling hl.monitor() here, so the
-- choice lands in the saved state and survives a logout like any other display
-- toggle. Switching it back on only clears the "disabled" flag -- the named
-- HDMI-A-1 rule above supplies the 720p mode and scale again by itself.
hl.bind(mod .. " + END", hl.dsp.exec_cmd("~/nixcfg/scripts/monitors.sh toggle HDMI-A-1"))
-- Meta+M = Pick which displays are on (same menu as the waybar tile)
hl.bind(mod .. " + M", hl.dsp.exec_cmd("~/nixcfg/scripts/monitors.sh menu"))

----------------------------------------
-- Session (matches Plasma)
----------------------------------------
-- Meta+L = Lock Session
hl.bind(mod .. " + L", hl.dsp.exec_cmd("hyprlock"))
-- Ctrl+Alt+Del = Logout menu
hl.bind("CTRL + ALT + DELETE", hl.dsp.exec_cmd("wlogout"))
-- Meta+Shift+P = Shut Down
hl.bind(mod .. " + SHIFT + P", hl.dsp.exec_cmd("systemctl poweroff"))
-- Meta+Shift+S = Sleep (lock then suspend)
hl.bind(mod .. " + SHIFT + S", hl.dsp.exec_cmd("hyprlock & systemctl suspend"))

----------------------------------------
-- Windows (matches Plasma)
----------------------------------------
-- Meta+Alt+Q / Alt+F4 = Close Window
hl.bind(mod .. " + ALT + Q", hl.dsp.window.close())
hl.bind("ALT + F4",          hl.dsp.window.close())
-- Meta+Ctrl+Esc = Kill Window (interactive click-to-kill)
hl.bind(mod .. " + CTRL + ESCAPE", hl.dsp.exec_cmd("hyprctl kill"))
-- Meta+F / Meta+PgUp = Maximize
hl.bind(mod .. " + F",     hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }))
hl.bind(mod .. " + PRIOR", hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }))
-- Meta+Alt+F = true fullscreen (covers waybar; Meta+F only maximizes)
hl.bind(mod .. " + ALT + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
-- Meta+Alt+O = fit the window to what an overscanning TV actually shows, for
-- watching video on a set that crops the edges. Toggles, using whatever
-- percentage that window's own screen has remembered -- set it once per
-- screen with `overscan.sh set 3` in a terminal, which moves nothing itself.
hl.bind(mod .. " + ALT + O", hl.dsp.exec_cmd("~/nixcfg/scripts/overscan.sh"))
-- Toggle floating
hl.bind(mod .. " + SHIFT + SPACE", hl.dsp.window.float({ action = "toggle" }))
-- Cycle windows
hl.bind(mod .. " + SPACE", hl.dsp.window.cycle_next())
-- Toggle dwindle split orientation (vertical/horizontal)
hl.bind(mod .. " + H", hl.dsp.exec_cmd("hyprctl dispatch layoutmsg togglesplit"))
-- Reload config
hl.bind(mod .. " + SHIFT + C", hl.dsp.exec_cmd("hyprctl reload"))
-- Exit session
hl.bind(mod .. " + SHIFT + E", hl.dsp.exit())

----------------------------------------
-- Focus (Meta+Arrow and Meta+Alt+Arrow, matches Plasma)
----------------------------------------
hl.bind(mod .. " + left",  hl.dsp.focus({ direction = "l" }))
hl.bind(mod .. " + right", hl.dsp.focus({ direction = "r" }))
hl.bind(mod .. " + up",    hl.dsp.focus({ direction = "u" }))
hl.bind(mod .. " + down",  hl.dsp.focus({ direction = "d" }))
hl.bind(mod .. " + ALT + left",  hl.dsp.focus({ direction = "l" }))
hl.bind(mod .. " + ALT + right", hl.dsp.focus({ direction = "r" }))
hl.bind(mod .. " + ALT + up",    hl.dsp.focus({ direction = "u" }))
hl.bind(mod .. " + ALT + down",  hl.dsp.focus({ direction = "d" }))

----------------------------------------
-- Move windows
----------------------------------------
-- Meta+Shift+Arrows = Move within tiling layout on the current desktop only
hl.bind(mod .. " + SHIFT + left",  hl.dsp.window.move({ direction = "l" }))
hl.bind(mod .. " + SHIFT + right", hl.dsp.window.move({ direction = "r" }))
hl.bind(mod .. " + SHIFT + up",    hl.dsp.window.move({ direction = "u" }))
hl.bind(mod .. " + SHIFT + down",  hl.dsp.window.move({ direction = "d" }))
-- Move within tiling layout (vim-style)
hl.bind(mod .. " + SHIFT + H", hl.dsp.window.move({ direction = "l" }))
hl.bind(mod .. " + SHIFT + J", hl.dsp.window.move({ direction = "d" }))
hl.bind(mod .. " + SHIFT + K", hl.dsp.window.move({ direction = "u" }))
hl.bind(mod .. " + SHIFT + L", hl.dsp.window.move({ direction = "r" }))

----------------------------------------
-- Workspaces (matches Plasma)
----------------------------------------
-- Meta+1-9,0 = Switch to Desktop
for i = 1, 10 do
    local key = i % 10 -- 10 maps to key 0
    hl.bind(mod .. " + " .. key, hl.dsp.focus({ workspace = i }))
end

-- Meta+Ctrl+Left/Right/Up/Down = Switch Desktop (matches Plasma)
hl.bind(mod .. " + CTRL + left",  hl.dsp.focus({ workspace = "-1" }))
hl.bind(mod .. " + CTRL + right", hl.dsp.focus({ workspace = "+1" }))
hl.bind(mod .. " + CTRL + up",    hl.dsp.focus({ workspace = "+1" }))
hl.bind(mod .. " + CTRL + down",  hl.dsp.focus({ workspace = "-1" }))

-- Meta+Ctrl+Shift+Left/Right = Move Window to Desktop (matches Plasma), stay on current desktop
hl.bind(mod .. " + CTRL + SHIFT + left",  hl.dsp.window.move({ workspace = "-1", follow = false }))
hl.bind(mod .. " + CTRL + SHIFT + right", hl.dsp.window.move({ workspace = "+1", follow = false }))

-- Meta+Shift+1-9,0 = Move Window to Numbered Desktop (bonus), stay on current desktop
for i = 1, 10 do
    local key = i % 10
    hl.bind(mod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i, follow = false }))
end

----------------------------------------
-- Window switching / Alt-Tab (matches Plasma)
----------------------------------------
hl.bind("ALT + TAB",               hl.dsp.window.cycle_next())
hl.bind("ALT + SHIFT + TAB",       hl.dsp.window.cycle_next({ next = false }))
hl.bind(mod .. " + TAB",           hl.dsp.window.cycle_next())
hl.bind(mod .. " + SHIFT + TAB",   hl.dsp.window.cycle_next({ next = false }))

----------------------------------------
-- Scratchpad
----------------------------------------
hl.bind(mod .. " + MINUS",         hl.dsp.window.move({ workspace = "special:scratchpad", follow = false }))
hl.bind(mod .. " + SHIFT + MINUS", hl.dsp.workspace.toggle_special("scratchpad"))

----------------------------------------
-- Keyboard layout (matches Plasma Meta+Alt+K)
-- Note: Meta+Alt+L conflicts with lock (Meta+L) so using Meta+Alt+P for prev
----------------------------------------
hl.bind(mod .. " + ALT + K", hl.dsp.exec_cmd("hyprctl switchxkblayout all next"))
hl.bind(mod .. " + ALT + P", hl.dsp.exec_cmd("hyprctl switchxkblayout all prev"))

----------------------------------------
-- Resize submap
----------------------------------------
hl.bind(mod .. " + R", hl.dsp.submap("resize"))

hl.define_submap("resize", function()
    hl.bind("H",      hl.dsp.window.resize({ x = -10, y = 0,   relative = true }), { repeating = true })
    hl.bind("J",      hl.dsp.window.resize({ x = 0,   y = 10,  relative = true }), { repeating = true })
    hl.bind("K",      hl.dsp.window.resize({ x = 0,   y = -10, relative = true }), { repeating = true })
    hl.bind("L",      hl.dsp.window.resize({ x = 10,  y = 0,   relative = true }), { repeating = true })
    hl.bind("left",   hl.dsp.window.resize({ x = -10, y = 0,   relative = true }), { repeating = true })
    hl.bind("down",   hl.dsp.window.resize({ x = 0,   y = 10,  relative = true }), { repeating = true })
    hl.bind("up",     hl.dsp.window.resize({ x = 0,   y = -10, relative = true }), { repeating = true })
    hl.bind("right",  hl.dsp.window.resize({ x = 10,  y = 0,   relative = true }), { repeating = true })
    hl.bind("RETURN", hl.dsp.submap("reset"))
    hl.bind("ESCAPE", hl.dsp.submap("reset"))
end)

----------------------------------------
-- Media / Volume / Brightness (matches Plasma)
----------------------------------------
hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd("~/nixcfg/scripts/volume_notify.sh up 5"),        { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd("~/nixcfg/scripts/volume_notify.sh down 5"),      { locked = true, repeating = true })
hl.bind("XF86AudioMute",         hl.dsp.exec_cmd("~/nixcfg/scripts/volume_notify.sh mute"),        { locked = true })
hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd("~/nixcfg/scripts/volume_notify.sh mic-mute"),    { locked = true })
-- F9 = Push-to-mute mic (mutes the default source, e.g. for Discord)
hl.bind("F9",                    hl.dsp.exec_cmd("~/nixcfg/scripts/volume_notify.sh mic-mute"),    { locked = true })
hl.bind("SHIFT + XF86AudioRaiseVolume", hl.dsp.exec_cmd("~/nixcfg/scripts/volume_notify.sh up 1"),   { locked = true, repeating = true })
hl.bind("SHIFT + XF86AudioLowerVolume", hl.dsp.exec_cmd("~/nixcfg/scripts/volume_notify.sh down 1"), { locked = true, repeating = true })
hl.bind("XF86AudioPlay",         hl.dsp.exec_cmd("playerctl play-pause"),   { locked = true })
hl.bind("XF86AudioPause",        hl.dsp.exec_cmd("playerctl play-pause"),   { locked = true })
hl.bind("XF86AudioNext",         hl.dsp.exec_cmd("playerctl next"),         { locked = true })
hl.bind("XF86AudioPrev",         hl.dsp.exec_cmd("playerctl previous"),     { locked = true })
hl.bind("XF86AudioStop",         hl.dsp.exec_cmd("playerctl stop"),         { locked = true })
hl.bind("XF86AudioRewind",       hl.dsp.exec_cmd("playerctl position 5-"),  { locked = true })
hl.bind("XF86AudioForward",      hl.dsp.exec_cmd("playerctl position 5+"),  { locked = true })
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl set 5%+"),  { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 5%-"),  { locked = true, repeating = true })
hl.bind("SHIFT + XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl set 1%+"), { locked = true, repeating = true })
hl.bind("SHIFT + XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 1%-"), { locked = true, repeating = true })

----------------------------------------
-- Screenshot (matches Plasma Spectacle)
----------------------------------------
hl.bind(mod .. " + SHIFT + PRINT", hl.dsp.exec_cmd("/home/benji/nixcfg/scripts/screenshot.sh"))
hl.bind("F12",                     hl.dsp.exec_cmd("/home/benji/nixcfg/scripts/screenshot.sh"))

----------------------------------------
-- Mouse -- drag/resize floating windows
----------------------------------------
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

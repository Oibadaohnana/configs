# dayz

Terminal browser for DayOne and official DayZ servers on Linux. Shows player
counts and required mods, and joins a server through Steam with the right mods
loaded.

## Usage

```
dayz            browse all DayOne and official servers
dayz namalsk    start with a filter
```

- **enter** joins the selected server
- **ctrl-r** refreshes the list
- type to filter by name, map or region (`dayone`, `livonia`, `DE`, ...)

The right panel shows the server details and which mods you have (✓) or are
missing (✗). When you join a server with missing mods, it lists them and opens
each Workshop page in Steam so you can subscribe, then waits for the downloads.

On first join it asks for your player name and saves it in
`~/.config/dayz/name`.

To list other servers too, put them in `~/.config/dayz/favorites`, one per
line, as an address or part of the server name. They show up at the top as
"Favorite":

```
172.111.51.165:2602   # The Refuge Deerisle No Bases
the refuge
```

In Steam, set DayZ's launch options to `%command%` (or `gamemoderun %command%`)
and tick **Always use this option → Run DayZ Client**.

## Install

### Without Nix

Needs Python 3 and [fzf](https://github.com/junegunn/fzf).

```
cp dayz.py ~/.local/bin/dayz
chmod +x ~/.local/bin/dayz
```

### Nix

```
nix run path:/path/to/dayz
```

NixOS, add the flake as an input and import the module:

```nix
inputs.dayz.url = "path:/path/to/dayz";
modules = [ inputs.dayz.nixosModules.default ];
```

Or without flakes: `environment.systemPackages = [ (pkgs.callPackage ./dayz/package.nix { }) ];`

## How it works

- Server list: [dayzsalauncher.com](https://dayzsalauncher.com) public API,
  cached for a minute in `~/.cache/dayz/servers.json`.
- "Favorite" = listed in `~/.config/dayz/favorites`; "DayOne" = server name
  starts with `DayOne`; "Official" = official shard.
- Mods are symlinked from the Workshop folder into the DayZ folder as
  `@ModName` and passed to the game with `-mod=`.
- The game is started with `steam -applaunch 221100 -connect=... -mod=...`.
  Steam can be native or Flatpak; set `DAYZ_STEAM_DIR` if your Steam folder is
  somewhere unusual.

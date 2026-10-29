#!/usr/bin/env python3
import gzip
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

API = "https://dayzsalauncher.com/api/v2/launcher/servers/dayz"
APPID = "221100"
MAX_AGE = 60
CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "dayz" / "servers.json"
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "dayz"
NAME_FILE = CONFIG / "name"
FAVORITES_FILE = CONFIG / "favorites"
FLATPAK_STEAM = Path.home() / ".var/app/com.valvesoftware.Steam/.local/share/Steam"
STEAM_ROOTS = [
    os.environ.get("DAYZ_STEAM_DIR"),
    Path.home() / ".local/share/Steam",
    Path.home() / ".steam/steam",
    FLATPAK_STEAM,
]
USAGE = """usage: dayz [search]

Browse DayOne and official DayZ servers and join one. Third person (3PP)
servers are hidden unless they are favorites.

  enter    join the selected server
  tab      switch to community servers sorted by players, and back
  ctrl-r   refresh the server list
  search   start with this filter, e.g. dayz namalsk

The player name is asked on first join and kept in ~/.config/dayz/name.

Extra servers go in ~/.config/dayz/favorites, one per line: an address
(ip:port) or part of the server name. Text after # is ignored.
Set DAYZ_STEAM_DIR if Steam lives somewhere unusual."""
MAPS = {
    "chernarusplus": "Chernarus",
    "enoch": "Livonia",
    "sakhal": "Sakhal",
    "nasdara": "Nasdara",
    "namalsk": "Namalsk",
    "deerisle": "Deer Isle",
    "banov": "Banov",
    "bitterroot": "Bitterroot",
    "deadfall": "Deadfall",
    "pripyat": "Pripyat",
    "esseker": "Esseker",
}
KINDS = ["Favorite", "DayOne", "Official", "Community"]
TABS = {"main": "Main> ", "community": "Community> "}
HEADERS = {
    "main": "enter: join  tab: community  ctrl-r: refresh  type to filter (e.g. dayone, namalsk, DE)",
    "community": "enter: join  tab: back to main  ctrl-r: refresh  community servers with players, busiest first",
}


def load_favorites():
    if not FAVORITES_FILE.exists():
        return []
    entries = (line.split("#", 1)[0].strip() for line in FAVORITES_FILE.read_text().splitlines())
    return [entry.lower() for entry in entries if entry]


FAVORITES = load_favorites()


def favorite(server):
    name = server["name"].lower()
    return any(entry == key(server) or entry in name for entry in FAVORITES)


def kind(server):
    if favorite(server):
        return "Favorite"
    if re.match(r"DayOne\s", server["name"]):
        return "DayOne"
    if server.get("shard") == "public":
        return "Official"
    return "Community"


def third_person(server):
    first = re.search(r"(?<!\d)1\s*pp|first[\s-]*person|1st[\s-]*person", server["name"], re.I)
    third = re.search(r"(?<!\d)3\s*pp|third[\s-]*person|3rd[\s-]*person", server["name"], re.I)
    if bool(first) != bool(third):
        return bool(third)
    return bool(server.get("firstPersonOnly"))


def wanted(server):
    if kind(server) == "Favorite":
        return True
    if third_person(server):
        return False
    return kind(server) != "Community" or server["players"]


def slim(server):
    fields = ["name", "gamePort", "players", "maxPlayers", "map", "version", "time", "timeAcceleration", "password", "shard"]
    mods = [{"name": m["name"], "steamWorkshopId": m["steamWorkshopId"]} for m in server.get("mods") or []]
    return {**{f: server.get(f) for f in fields}, "endpoint": {"ip": server["endpoint"]["ip"]}, "mods": mods}


def key(server):
    return f"{server['endpoint']['ip']}:{server['gamePort']}"


def fetch(max_age=MAX_AGE):
    fresh = CACHE.exists() and time.time() - CACHE.stat().st_mtime < max_age
    if fresh and not (FAVORITES_FILE.exists() and FAVORITES_FILE.stat().st_mtime > CACHE.stat().st_mtime):
        return json.loads(CACHE.read_text())
    request = urllib.request.Request(API, headers={"Accept-Encoding": "gzip", "User-Agent": "dayz-browser"})
    with urllib.request.urlopen(request, timeout=60) as response:
        raw = response.read()
        if response.headers.get("Content-Encoding") == "gzip":
            raw = gzip.decompress(raw)
    servers = [slim(s) for s in json.loads(raw)["result"] if wanted(s)]
    servers.sort(key=lambda s: (KINDS.index(kind(s)), -s["players"], s["name"]))
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    tmp = CACHE.with_suffix(".tmp")
    tmp.write_text(json.dumps(servers))
    tmp.replace(CACHE)
    return servers


def find_library():
    for root in filter(None, STEAM_ROOTS):
        root = Path(root)
        libraries = [root]
        folders = root / "steamapps/libraryfolders.vdf"
        if folders.exists():
            libraries += [Path(p) for p in re.findall(r'"path"\s+"([^"]+)"', folders.read_text(errors="ignore"))]
        for library in libraries:
            if (library / "steamapps/common/DayZ").is_dir():
                return library / "steamapps"
    return None


LIBRARY = find_library()
GAME = LIBRARY / "common/DayZ" if LIBRARY else None
WORKSHOP = LIBRARY / "workshop/content" / APPID if LIBRARY else None


def installed(mod):
    return bool(WORKSHOP) and (WORKSHOP / str(mod["steamWorkshopId"]) / "meta.cpp").exists()


def player_name():
    if os.environ.get("DAYZ_PLAYER_NAME"):
        return os.environ["DAYZ_PLAYER_NAME"]
    if NAME_FILE.exists() and NAME_FILE.read_text().strip():
        return NAME_FILE.read_text().strip()
    name = ""
    while not name:
        name = input("Player name to use in DayZ: ").strip()
    NAME_FILE.parent.mkdir(parents=True, exist_ok=True)
    NAME_FILE.write_text(name + "\n")
    print(f"Saved to {NAME_FILE}\n")
    return name


def line(server):
    players = f"{server['players']}/{server['maxPlayers']}"
    full = "\033[31m" if server["players"] >= server["maxPlayers"] else ("\033[32m" if server["players"] else "\033[90m")
    missing = sum(not installed(m) for m in server["mods"])
    mods = f"\033[33m{missing} missing\033[0m" if missing else ""
    world = MAPS.get(server["map"].lower(), server["map"])
    return f"{key(server)}\t{full}{players:>7}\033[0m  {kind(server):<9}  {world:<10}  {server['name']}  {mods}"


def find(servers, address):
    return next((s for s in servers if key(s) == address), None)


def preview(address):
    server = find(fetch(float("inf")), address)
    if not server:
        print("Server not found, press ctrl-r to refresh")
        return
    print(f"\033[1m{server['name']}\033[0m\n")
    print(f"Address   {address}")
    print(f"Players   {server['players']}/{server['maxPlayers']}")
    print(f"Map       {MAPS.get(server['map'].lower(), server['map'])}")
    print(f"Version   {server.get('version', '?')}")
    print(f"Time      {server.get('time', '?')} (x{server.get('timeAcceleration', '?')})")
    print(f"Password  {'yes' if server.get('password') else 'no'}")
    mods = server["mods"]
    print(f"\nMods ({len(mods)})" if mods else "\nNo mods")
    for mod in mods:
        mark = "\033[32m✓\033[0m" if installed(mod) else "\033[31m✗\033[0m"
        print(f"  {mark} {mod['name']}  \033[90m{mod['steamWorkshopId']}\033[0m")


def steam(*args):
    if shutil.which("steam"):
        command = ["steam"]
    elif shutil.which("flatpak") and FLATPAK_STEAM.exists():
        command = ["flatpak", "run", "com.valvesoftware.Steam"]
    else:
        sys.exit("Steam not found")
    subprocess.Popen([*command, *args], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def subscribe(mods):
    missing = [m for m in mods if not installed(m)]
    if not missing:
        return
    print(f"\033[33mMissing {len(missing)} of {len(mods)} required mods:\033[0m")
    for mod in missing:
        print(f"  \033[31m✗\033[0m {mod['name']}  \033[90m{mod['steamWorkshopId']}\033[0m")
    if input("\nOpen their Workshop pages in Steam to subscribe? [Y/n] ").strip().lower() in ("n", "no"):
        sys.exit("Not joining, the server needs these mods")
    print()
    for index, mod in enumerate(missing, 1):
        steam(f"steam://url/CommunityFilePage/{mod['steamWorkshopId']}")
        input(f"[{index}/{len(missing)}] {mod['name']}: press Enter once subscribed ")
    print("\nWaiting for Steam to finish downloading (ctrl-c to cancel)")
    while missing:
        missing = [m for m in missing if not installed(m)]
        names = ", ".join(m["name"] for m in missing)
        print(f"\r\033[K{len(missing)} left: {names}"[:200], end="", flush=True)
        if missing:
            time.sleep(3)
    print("\r\033[KAll mods downloaded")


def link(mods):
    existing = {}
    for path in GAME.glob("@*"):
        if path.is_symlink():
            existing.setdefault(os.readlink(path), []).append(path)
    names = []
    for mod in mods:
        mod_id = str(mod["steamWorkshopId"])
        target = str(WORKSHOP / mod_id)
        name = "@" + (re.sub(r"[^A-Za-z0-9]", "", mod["name"]) or mod_id)
        if name in names or ((GAME / name).exists() and not (GAME / name).is_symlink()):
            name = f"@{mod_id}"
        path = GAME / name
        for old in existing.get(target, []):
            if old != path:
                old.unlink()
        if path.is_symlink() and os.readlink(path) != target:
            path.unlink()
        if not path.is_symlink():
            path.symlink_to(target)
        names.append(name)
    return names


def join(server):
    if not GAME:
        sys.exit("DayZ not found in any Steam library, set DAYZ_STEAM_DIR to your Steam folder")
    name = player_name()
    print(f"\033[1m{server['name']}\033[0m  {server['players']}/{server['maxPlayers']}\n")
    mods = server["mods"]
    subscribe(mods)
    args = [f"-connect={key(server)}", "-nolauncher", "-nosplash", "-skipintro", f"-name={name}"]
    if mods:
        args.append("-mod=" + ";".join(link(mods)))
    if server["players"] >= server["maxPlayers"]:
        print("Server is full right now, you may end up in a queue")
    print("Launching DayZ")
    steam("-applaunch", APPID, *args)


def listing(servers, tab):
    return "\n".join(line(s) for s in servers if (kind(s) == "Community") == (tab == "community"))


def current_tab():
    return next((tab for tab, prompt in TABS.items() if prompt == os.environ.get("FZF_PROMPT")), "main")


def action(name):
    cmd = shlex.join([sys.executable, os.path.realpath(__file__)])
    tab = current_tab()
    if name == "refresh":
        print(f"reload[{cmd} --list {tab} --refresh]")
        return
    tab = "community" if tab == "main" else "main"
    print(f"change-prompt[{TABS[tab]}]+change-header[{HEADERS[tab]}]+reload[{cmd} --list {tab}]+first")


def browse(query):
    print("Fetching server list...", file=sys.stderr)
    servers = fetch()
    cmd = shlex.join([sys.executable, os.path.realpath(__file__)])
    fzf = subprocess.run(
        [
            "fzf", "--ansi", "--no-sort", "--layout=reverse", "--delimiter=\t", "--with-nth=2",
            "--query", query,
            "--prompt", TABS["main"],
            "--header", HEADERS["main"],
            "--preview", f"{cmd} --preview {{1}}",
            "--preview-window", "right,45%,wrap",
            "--bind", f"tab:transform({cmd} --action switch)",
            "--bind", f"ctrl-r:transform({cmd} --action refresh)",
        ],
        input=listing(servers, "main"),
        stdout=subprocess.PIPE,
        text=True,
    )
    if fzf.returncode != 0 or not fzf.stdout.strip():
        return
    address = fzf.stdout.split("\t", 1)[0]
    server = find(fetch(), address)
    if not server:
        sys.exit("Server disappeared from the list, try again")
    join(server)


def main():
    args = sys.argv[1:]
    try:
        if args[:1] in (["-h"], ["--help"]):
            print(USAGE)
        elif args[:1] == ["--list"]:
            print(listing(fetch(0 if "--refresh" in args else MAX_AGE), args[1]))
        elif args[:1] == ["--action"]:
            action(args[1])
        elif args[:1] == ["--preview"]:
            preview(args[1])
        else:
            browse(" ".join(args))
    except KeyboardInterrupt:
        print()
        sys.exit(130)


main()

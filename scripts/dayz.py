#!/usr/bin/env python3
import gzip
import json
import os
import re
import shlex
import select
import shutil
import socket
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
FLATPAK_HOME = Path.home() / ".var/app/com.valvesoftware.Steam"
FLATPAK_STEAM = FLATPAK_HOME / ".local/share/Steam"
STEAM_PIPES = [Path.home() / ".steam/steam.pipe", FLATPAK_HOME / ".steam/steam.pipe"]
STEAM_LOG = CACHE.parent / "steam.log"
PINGS = CACHE.parent / "pings.json"
STEAM_ROOTS = [
    os.environ.get("DAYZ_STEAM_DIR"),
    Path.home() / ".local/share/Steam",
    Path.home() / ".steam/steam",
    FLATPAK_STEAM,
]
USAGE = """usage: dayz [search]

Browse DayOne and official DayZ servers and join one. Third person (3PP)
servers are hidden unless they are favorites, which are listed at the top.

  enter      join the selected server
  ctrl-f     mark or unmark the selected server as a favorite
  tab        switch to community servers sorted by players, and back
  ctrl-r     refresh the server list
  search     start with this filter, e.g. dayz namalsk

Ping is measured from here and kept for 5 minutes, ctrl-r measures again.

The player name is asked on first join and kept in ~/.config/dayz/name.

Favorites are kept in ~/.config/dayz/favorites, one per line: an address
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
A2S_INFO = b"\xff\xff\xff\xffTSource Engine Query\x00"
PING_TIMEOUT = 1
PING_GAP = 0.0005
PING_AGE = 300
KINDS = ["DayOne", "Official", "Community"]
TABS = {"main": "Main> ", "community": "Community> "}
HEADERS = {
    "main": "favorites, DayOne and official servers, type to filter (e.g. dayone, namalsk, DE)",
    "community": "community servers with players, busiest first",
}


def next_tab(tab):
    return "community" if tab == "main" else "main"


def keys(tab):
    hints = [("enter", "join"), ("ctrl-f", "favorite"), ("tab", next_tab(tab)), ("ctrl-r", "refresh")]
    return " " + "  ".join(f"\033[1m{key}\033[0m {what}" for key, what in hints) + " "


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


def listed(server):
    if third_person(server):
        return False
    return kind(server) != "Community" or server["players"]


def wanted(server):
    return favorite(server) or listed(server)


def shown(server, tab):
    if favorite(server):
        return tab == "main"
    return listed(server) and (kind(server) == "Community") == (tab == "community")


def order(server):
    return (KINDS.index(kind(server)), -server["players"], server["name"])


def slim(server):
    fields = ["name", "gamePort", "players", "maxPlayers", "map", "version", "time", "timeAcceleration", "password", "shard"]
    mods = [{"name": m["name"], "steamWorkshopId": m["steamWorkshopId"]} for m in server.get("mods") or []]
    return {**{f: server.get(f) for f in fields}, "endpoint": {"ip": server["endpoint"]["ip"], "port": server["endpoint"]["port"]}, "mods": mods}


def key(server):
    return f"{server['endpoint']['ip']}:{server['gamePort']}"


def measure(addresses):
    answers = {}
    sent = {}
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:

        def receive(wait):
            while select.select([sock], [], [], wait)[0]:
                wait = 0
                try:
                    _, source = sock.recvfrom(4096)
                except OSError:
                    continue
                if source in sent and source not in answers:
                    answers[source] = round((time.monotonic() - sent[source]) * 1000)

        for target in addresses:
            try:
                sock.sendto(A2S_INFO, target)
                sent[target] = time.monotonic()
            except OSError:
                pass
            receive(PING_GAP)
        deadline = time.monotonic() + PING_TIMEOUT
        while len(answers) < len(sent) and time.monotonic() < deadline:
            receive(deadline - time.monotonic())
    return answers


def load_pings():
    try:
        return json.loads(PINGS.read_text())
    except (OSError, ValueError):
        return {}


def ping_servers(servers, refresh=False):
    pings = load_pings()
    now = time.time()
    stale = {}
    for server in servers:
        entry = pings.get(key(server))
        if refresh or not entry or now - entry[1] > PING_AGE:
            stale[(server["endpoint"]["ip"], server["endpoint"]["port"])] = key(server)
    if stale:
        answers = measure(stale)
        for target, address in stale.items():
            pings[address] = [answers.get(target, pings.get(address, [None])[0]), now]
        PINGS.parent.mkdir(parents=True, exist_ok=True)
        tmp = PINGS.with_suffix(".tmp")
        tmp.write_text(json.dumps(pings))
        tmp.replace(PINGS)
    return {address: entry[0] for address, entry in pings.items()}


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
    servers.sort(key=order)
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


def ping(ms):
    if ms is None:
        return "\033[90m    -\033[0m"
    color = "\033[32m" if ms < 80 else ("\033[33m" if ms < 150 else "\033[31m")
    return f"{color}{ms:>3}ms\033[0m"


def line(server, pings):
    players = f"{server['players']}/{server['maxPlayers']}"
    full = "\033[31m" if server["players"] >= server["maxPlayers"] else ("\033[32m" if server["players"] else "\033[90m")
    missing = sum(not installed(m) for m in server["mods"])
    mods = f"\033[33m{missing} missing\033[0m" if missing else ""
    world = MAPS.get(server["map"].lower(), server["map"])
    star = "\033[33m*\033[0m" if favorite(server) else " "
    return f"{key(server)}\t{star}{full}{players:>7}\033[0m  {ping(pings.get(key(server)))}  {kind(server):<9}  {world:<10}  {server['name']}  {mods}"


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
    ms = load_pings().get(address, [None])[0]
    print(f"Ping      {f'{ms} ms' if ms is not None else 'no answer'}")
    print(f"Map       {MAPS.get(server['map'].lower(), server['map'])}")
    print(f"Version   {server.get('version', '?')}")
    print(f"Time      {server.get('time', '?')} (x{server.get('timeAcceleration', '?')})")
    print(f"Password  {'yes' if server.get('password') else 'no'}")
    mods = server["mods"]
    print(f"\nMods ({len(mods)})" if mods else "\nNo mods")
    for mod in mods:
        mark = "\033[32m✓\033[0m" if installed(mod) else "\033[31m✗\033[0m"
        print(f"  {mark} {mod['name']}  \033[90m{mod['steamWorkshopId']}\033[0m")


def steam(*args, log=subprocess.DEVNULL):
    if shutil.which("steam"):
        command = ["steam"]
    elif shutil.which("flatpak") and FLATPAK_STEAM.exists():
        command = ["flatpak", "run", "com.valvesoftware.Steam"]
    else:
        sys.exit("Steam not found")
    return subprocess.Popen([*command, *args], cwd=Path.home(), stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)


def processes():
    for cmdline in Path("/proc").glob("[0-9]*/cmdline"):
        try:
            yield cmdline.read_bytes().split(b"\0")
        except OSError:
            pass


def game_running():
    return any(f"AppId={APPID}".encode() in args for args in processes())


def steam_running():
    return any(args[0].endswith(b"ubuntu12_32/steam") for args in processes())


def hand_over(pipe, args):
    STEAM_LOG.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(3):
        before = pipe.stat().st_mtime
        with STEAM_LOG.open("w") as log:
            process = steam("-applaunch", APPID, *args, log=log)
        deadline = time.time() + 15
        while time.time() < deadline:
            if pipe.stat().st_mtime != before:
                return
            time.sleep(0.5)
        process.kill()
        if attempt < 2:
            print("Steam did not pick up the launch, trying again")
    sys.exit(f"Steam did not respond, its output is in {STEAM_LOG}")


def launch(args):
    pipe = next((p for p in STEAM_PIPES if p.exists()), None) if steam_running() else None
    if pipe:
        hand_over(pipe, args)
    else:
        print("Starting Steam")
        steam("-applaunch", APPID, *args)
    print("Waiting for DayZ to start (ctrl-c to stop waiting)")
    deadline = time.time() + (60 if pipe else 300)
    while time.time() < deadline:
        if game_running():
            print("DayZ is running")
            return
        time.sleep(1)
    sys.exit("DayZ did not start, check Steam for a dialog or an update")


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
    if game_running():
        print("DayZ is still running, waiting for it to close (ctrl-c to cancel)")
        while game_running():
            time.sleep(1)
    print("Launching DayZ")
    launch(args)


def listing(servers, tab, refresh=False):
    pinned = [s for s in sorted(servers, key=lambda s: (tab == "main" and not favorite(s), order(s))) if shown(s, tab)]
    pings = ping_servers(pinned, refresh)
    return "\n".join(line(s, pings) for s in pinned)


def toggle_favorite(address):
    server = find(fetch(float("inf")), address)
    if not server:
        return
    lines = FAVORITES_FILE.read_text().splitlines() if FAVORITES_FILE.exists() else []
    if favorite(server):
        name = server["name"].lower()
        entries = [line.split("#", 1)[0].strip().lower() for line in lines]
        lines = [line for line, entry in zip(lines, entries) if not entry or (entry != address and entry not in name)]
    else:
        lines.append(f"{address:<20} # {server['name'].strip()}")
    FAVORITES_FILE.parent.mkdir(parents=True, exist_ok=True)
    FAVORITES_FILE.write_text("".join(line + "\n" for line in lines))
    if CACHE.exists():
        cached = CACHE.stat().st_mtime
        os.utime(FAVORITES_FILE, (cached, cached))


def current_tab():
    return next((tab for tab, prompt in TABS.items() if prompt == os.environ.get("FZF_PROMPT")), "main")


def action(name, address=None):
    cmd = shlex.join([sys.executable, os.path.realpath(__file__)])
    tab = current_tab()
    if name == "refresh":
        print(f"reload[{cmd} --list {tab} --refresh]")
        return
    if name == "favorite":
        if address:
            toggle_favorite(address)
        print(f"track-current+reload[{cmd} --list {tab}]")
        return
    tab = next_tab(tab)
    print(f"change-prompt[{TABS[tab]}]+change-header[{HEADERS[tab]}]+change-preview-label[{keys(tab)}]+reload[{cmd} --list {tab}]+first")


def browse(query):
    print("Fetching server list...", file=sys.stderr)
    servers = fetch()
    cmd = shlex.join([sys.executable, os.path.realpath(__file__)])
    fzf = subprocess.run(
        [
            "fzf", "--ansi", "--no-sort", "--layout=reverse", "--delimiter=\t", "--with-nth=2", "--id-nth=1",
            "--query", query,
            "--prompt", TABS["main"],
            "--header", HEADERS["main"],
            "--preview", f"{cmd} --preview {{1}}",
            "--preview-window", "right,45%,wrap,border-rounded",
            "--preview-label", keys("main"),
            "--preview-label-pos", "-2:bottom",
            "--bind", f"tab:transform({cmd} --action switch)",
            "--bind", f"ctrl-r:transform({cmd} --action refresh)",
            "--bind", f"ctrl-f:transform({cmd} --action favorite {{1}})",
        ],
        input=listing(servers, "main"),
        stdout=subprocess.PIPE,
        text=True,
    )
    if fzf.returncode != 0 or not fzf.stdout.strip():
        return
    address = fzf.stdout.split("\t", 1)[0]
    server = find(fetch(float("inf")), address)
    if not server:
        sys.exit("Server disappeared from the list, try again")
    join(server)


def main():
    args = sys.argv[1:]
    try:
        if args[:1] in (["-h"], ["--help"]):
            print(USAGE)
        elif args[:1] == ["--list"]:
            refresh = "--refresh" in args
            print(listing(fetch(0 if refresh else MAX_AGE), args[1], refresh))
        elif args[:1] == ["--action"]:
            action(*args[1:3])
        elif args[:1] == ["--preview"]:
            preview(args[1])
        else:
            browse(" ".join(args))
    except KeyboardInterrupt:
        print()
        sys.exit(130)


main()

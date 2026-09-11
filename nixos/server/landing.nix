# baggly.de -- the front door. Lists the games and links to their subdomains.
#
# Adding a game is one entry in `games` below plus its own module under
# server/games/. The page is a store path built from that list, so there is no
# HTML to edit by hand and no way for the list and the vhosts to drift apart
# without someone noticing.
{
  pkgs,
  lib,
  ...
}: let
  domain = "baggly.de";

  # status: "live" -> linked card. "soon" -> dimmed, no link. "desktop" -> a
  # game people run locally; only its relay lives on this box, so there is
  # nothing to link to.
  games = [
    {
      name = "Bobby Dangling";
      status = "live";
      host = "bobby.${domain}";
      blurb = "Swing, dangle, drop. Multiplayer in the browser -- open the link, share the room code.";
    }
    {
      name = "Bank Bobbery";
      status = "soon";
      host = "bank.${domain}";
      blurb = "Rob the bank, outrun the guards. Comes with a level editor in the browser.";
    }
    {
      name = "Worms Whup";
      status = "desktop";
      host = null;
      blurb = "Turn-based artillery for the desktop. The match runs on your machine; this server only introduces the players.";
    }
  ];

  badge = {
    live = "playable";
    soon = "coming soon";
    desktop = "desktop game";
  };

  card = g: let
    inner = ''
      <h2>${g.name}</h2>
      <p>${g.blurb}</p>
      <span class="badge badge-${g.status}">${badge.${g.status}}</span>
      ${lib.optionalString (g.host != null && g.status == "live") ''<span class="host">${g.host}</span>''}
    '';
  in
    if g.status == "live"
    then ''<a class="card" href="https://${g.host}/">${inner}</a>''
    else ''<div class="card card-inactive">${inner}</div>'';

  page = pkgs.writeTextDir "index.html" ''
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>baggly.de</title>
    <meta name="description" content="Games on baggly.de">
    <style>
      :root {
        --bg: #11131a;
        --panel: #1a1d27;
        --panel-hover: #222634;
        --line: #2c3142;
        --text: #e7e9f0;
        --muted: #9aa1b5;
        --accent: #ffc857;
      }
      @media (prefers-color-scheme: light) {
        :root {
          --bg: #f6f7fb;
          --panel: #ffffff;
          --panel-hover: #ffffff;
          --line: #e0e3ee;
          --text: #1a1d27;
          --muted: #5d6478;
          --accent: #b4761a;
        }
      }
      * { box-sizing: border-box; }
      body {
        margin: 0;
        padding: 4rem 1.25rem 5rem;
        background: var(--bg);
        color: var(--text);
        font: 16px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif;
      }
      main { max-width: 54rem; margin: 0 auto; }
      header { margin-bottom: 3rem; }
      h1 {
        margin: 0 0 .4rem;
        font-size: clamp(2.2rem, 7vw, 3.4rem);
        letter-spacing: -.02em;
      }
      h1 .dot { color: var(--accent); }
      .tagline { margin: 0; color: var(--muted); font-size: 1.05rem; }
      .grid {
        display: grid;
        gap: 1rem;
        grid-template-columns: repeat(auto-fit, minmax(17rem, 1fr));
      }
      .card {
        display: block;
        padding: 1.4rem 1.5rem;
        background: var(--panel);
        border: 1px solid var(--line);
        border-radius: 14px;
        color: inherit;
        text-decoration: none;
        transition: background .15s, border-color .15s, transform .15s;
      }
      .card:hover, .card:focus-visible {
        background: var(--panel-hover);
        border-color: var(--accent);
        transform: translateY(-2px);
      }
      .card-inactive { opacity: .62; }
      .card h2 { margin: 0 0 .5rem; font-size: 1.25rem; }
      .card p { margin: 0 0 1rem; color: var(--muted); font-size: .95rem; }
      .badge {
        display: inline-block;
        padding: .15rem .6rem;
        border-radius: 999px;
        font-size: .75rem;
        letter-spacing: .04em;
        text-transform: uppercase;
      }
      .badge-live { background: var(--accent); color: #11131a; }
      .badge-soon, .badge-desktop {
        background: transparent;
        border: 1px solid var(--line);
        color: var(--muted);
      }
      .host {
        margin-left: .6rem;
        color: var(--muted);
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        font-size: .8rem;
      }
      footer {
        margin-top: 3.5rem;
        color: var(--muted);
        font-size: .85rem;
      }
    </style>
    </head>
    <body>
    <main>
      <header>
        <h1>baggly<span class="dot">.</span>de</h1>
        <p class="tagline">Small games, run on one small server.</p>
      </header>

      <div class="grid">
    ${lib.concatMapStringsSep "\n" card games}
      </div>

      <footer>Every game lives on its own subdomain of baggly.de.</footer>
    </main>
    </body>
    </html>
  '';
in {
  # default = true so the wildcard DNS record has somewhere to land: any
  # subdomain without a vhost of its own -- a typo, an old link, a game not
  # wired up yet -- gets this page rather than nginx's blank built-in 404.
  # The wildcard cert covers those names too, so they arrive without a
  # certificate warning first.
  services.nginx.virtualHosts."${domain}" = {
    default = true;
    serverAliases = ["www.${domain}"];
    # No enableACME: the wildcard cert in web.nix names the apex and covers
    # www through *.baggly.de.
    useACMEHost = domain;
    forceSSL = true;
    root = page;
  };
}

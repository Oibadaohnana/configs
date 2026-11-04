# Muskelatlas -- the 3D skeleton and muscle atlas at https://anatomie.buggly.de.
#
# nginx terminates TLS with the shared *.buggly.de cert and proxies to the
# loopback port below, on the same terms as the other apps. The app itself is
# the repo's own Rust server: it serves the viewer and a small JSON API.
#
# The 3D models are NOT in the flake. They are ~80 MB of generated .glb files,
# built from the BodyParts3D and Z-Anatomy downloads on the laptop and kept out
# of git, so they are uploaded by hand like ./share.nix -- see "The models"
# below. Until they are there the page loads but stays empty.
#
# Moving the pin to newer code is `anatomieupdate`, then `bsyss`. New models
# need no rebuild at all, only the rsync.
{
  pkgs,
  anatomy,
  ...
}: let
  domain = "anatomie.buggly.de";
  app = anatomy.packages.${pkgs.stdenv.hostPlatform.system}.default;
  # 8787 bobby-dangling, 8788 worms-whup, 8789 todo, 8790 makinglist, 8791
  # bank-bobbery, 8792 split, 8793 bims, 8794-8802 grimgobber, 8803 gtp, 8804
  # calendar.
  port = "8805";
  # benji-owned so the upload is a plain rsync with no sudo. World-readable:
  # the service runs as a DynamicUser, and the password sits in front of nginx,
  # not on the files.
  models = "/var/lib/anatomie/models";

  # The server wants one directory holding index.html, app.js, data/ and
  # models/. Everything but models/ comes from the store.
  web = pkgs.runCommand "anatomie-web" {} ''
    mkdir $out
    ln -s ${app}/share/muskelatlas/web/* $out/
    ln -s ${models} $out/models
  '';

  # The door. Deliberately not secure: one fixed password, compared in plain
  # text by nginx, and a cookie holding that same password. It keeps casual
  # visitors and crawlers out and nothing more -- the password is in the nix
  # store and in this repo. Anything that matters belongs behind a real login
  # like split.nix has.
  password = "koerper";
  cookie = "anatomie";
  loginPage = pkgs.writeText "anatomie-login.html" ''
    <!doctype html>
    <html lang="de">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Muskelatlas</title>
    <style>
      :root { --bg: #11131a; --panel: #1a1d27; --line: #2c3142; --text: #e7e9f0; --muted: #9aa1b5; --accent: #e9d8b4; }
      @media (prefers-color-scheme: light) {
        :root { --bg: #f6f7fb; --panel: #fff; --line: #e0e3ee; --text: #1a1d27; --muted: #5d6478; --accent: #9a7b3f; }
      }
      * { box-sizing: border-box; }
      body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 1rem;
             background: var(--bg); color: var(--text); font: 16px/1.5 system-ui, sans-serif; }
      form { width: 100%; max-width: 20rem; padding: 1.75rem; background: var(--panel);
             border: 1px solid var(--line); border-radius: 14px; }
      h1 { margin: 0 0 1.25rem; font-size: 1.4rem; }
      input, button { width: 100%; padding: .65rem .8rem; border-radius: 8px; font: inherit; }
      input { border: 1px solid var(--line); background: var(--bg); color: inherit; }
      button { margin-top: .75rem; border: 0; background: var(--accent); color: var(--bg); cursor: pointer; }
      #err { margin: .75rem 0 0; color: var(--accent); }
    </style>
    </head>
    <body>
    <form method="get" action="/login">
      <h1>Muskelatlas</h1>
      <input type="password" name="pw" placeholder="Passwort" autofocus required>
      <button>Öffnen</button>
      <p id="err" hidden>Falsches Passwort.</p>
    </form>
    <script>
      if (new URLSearchParams(location.search).has('pw')) document.getElementById('err').hidden = false;
    </script>
    </body>
    </html>
  '';
in {
  systemd.tmpfiles.rules = [
    "d /var/lib/anatomie 0755 benji users -"
    "d ${models} 0755 benji users -"
  ];

  systemd.services.anatomie = {
    description = "Muskelatlas, the 3D anatomy atlas";
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target"];

    serviceConfig = {
      # The server binds 127.0.0.1 itself -- nginx is the only way in.
      ExecStart = "${app}/bin/muskelatlas server --port ${port} --web ${web}";
      Restart = "on-failure";
      # Reads files and nothing else; no state of its own.
      DynamicUser = true;

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
      SystemCallFilter = ["@system-service"];
      # It parses atlas.json (~0.5 MB) per request and streams the rest. Far
      # more than it uses, small enough that a leak kills the unit, not the box.
      MemoryMax = "128M";
    };
  };

  # The models
  # ----------
  # Built on the laptop with `cargo run --release -- build` in the anatomy
  # repo, then pushed from there:
  #
  #      rsync -av --delete web/models/ benji@45.129.182.102:/var/lib/anatomie/models/
  #
  # The server reads them per request, so no restart. Browsers revalidate every
  # file (the app sends Cache-Control: no-cache), so a reload shows them.

  # Behind the shared wildcard cert -- see ./web.nix.
  services.nginx.virtualHosts.${domain} = {
    useACMEHost = "buggly.de";
    forceSSL = true;

    # Everything without the cookie goes to the password page. `return` is the
    # one thing that is always safe inside an nginx `if`.
    locations."/" = {
      proxyPass = "http://127.0.0.1:${port}";
      extraConfig = ''
        if ($cookie_${cookie} != "${password}") {
          return 302 /login;
        }
      '';
    };

    # The form submits here as ?pw=. Right: set the cookie (400 days, so a
    # browser stays in) and go to the atlas. Wrong or none: the form again.
    #
    # The cookie goes through a variable rather than an add_header inside the
    # `if`: a nested add_header drops the outer ones, and the config check
    # (gixy) refuses to build it. nginx skips a header whose value is empty.
    locations."= /login".extraConfig = ''
      set $anatomie_cookie "";
      if ($arg_pw = "${password}") {
        set $anatomie_cookie "${cookie}=${password}; Path=/; Max-Age=34560000; Secure; HttpOnly; SameSite=Lax";
        return 302 /;
      }
      default_type text/html;
      add_header Set-Cookie $anatomie_cookie;
      add_header Cache-Control "no-store";
      alias ${loginPage};
    '';
  };
}

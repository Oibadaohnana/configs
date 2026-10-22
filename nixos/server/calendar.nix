# Shared calendar, with reminders as push notifications.
#
# Served over HTTPS at https://calendar.buggly.de -- nginx terminates TLS with
# the shared *.buggly.de cert and proxies to the loopback port below, on the
# same terms as split.nix and todo.nix.
#
# One password for everybody who shares the calendar, same as split: the door
# keeps the internet out. Who an event belongs to (its colour, whose phone gets
# the reminder) is picked per device inside the app, under People.
#
# Before this serves anything, the password hash has to exist: the unit fails
# on a box where /etc/calendar/pw.hash is missing. See "The password" below.
#
# Moving the pin to newer work is `calendarupdate`, then `bsyss` -- the same
# two steps as split, todo and the games.
{
  config,
  pkgs,
  calendar,
  ...
}: let
  app = calendar.packages.${pkgs.stdenv.hostPlatform.system}.default;
  # 8787 bobby-dangling, 8788 worms-whup, 8789 todo, 8790 makinglist, 8791
  # bank-bobbery, 8792 split, 8793 bims, 8794 grimgobber's door with its eight
  # lobbies on 8795-8802, 8803 gtp -- so the first free one is past those.
  port = "8804";
  # Root-owned, outside the state directory: the service reads it through
  # systemd's credential mechanism before it drops privileges, so the running
  # process never has permission to open the file itself.
  hashFile = "/etc/calendar/pw.hash";
in {
  systemd.services.calendar = {
    description = "Shared calendar with push reminders";
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target"];

    environment = {
      # Loopback only -- nginx is the public face and the only thing that can
      # reach this port. The server also trusts nginx's X-Real-IP for its
      # login limit, which is only safe while nothing else can connect.
      HOST = "127.0.0.1";
      PORT = port;
      # StateDirectory below creates and owns this path: calendar.db, plus
      # vapid.json -- the push keys. Losing those means every phone has to turn
      # reminders on again, so they are part of the backup below.
      DATA_DIR = "/var/lib/calendar";
      # Reminder times are wall-clock times ("09:00 dentist"), so the server
      # has to agree with the people using it about which wall.
      TZ = config.time.timeZone;
      # Sent to Google / Apple / Mozilla with every push, as the contact for
      # this sender. Apple rejects placeholder addresses.
      VAPID_SUBJECT = "mailto:${config.security.acme.defaults.email}";

      # No password variable here on purpose. The hash arrives as the systemd
      # credential below, which the server finds via CREDENTIALS_DIRECTORY.
      # The Secure flag on the session cookie needs no switch either: nginx
      # sends X-Forwarded-Proto https (recommendedProxySettings) and the
      # server sets Secure from that.
    };

    serviceConfig = {
      ExecStart = "${app}/bin/calendar-server";
      Restart = "on-failure";
      LoadCredential = "pwhash:${hashFile}";
      # No account to create or clean up; the calendar lands in /var/lib/calendar.
      DynamicUser = true;
      StateDirectory = "calendar";

      # It parses JSON from whoever reaches it -- lock it down the same way
      # split and the game servers are.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      # AF_UNIX on top of the internet families: glibc asks nscd over a unix
      # socket when Node resolves the push services' hostnames.
      RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
      SystemCallFilter = ["@system-service"];
      # Node plus a SQLite file of events. Plenty, and still small enough that
      # a leak kills the unit rather than the box. (No MemoryDenyWriteExecute:
      # V8's JIT needs writable+executable pages.)
      MemoryMax = "256M";
    };
  };

  # On PATH so the password can be hashed without hunting for the store path.
  # The program is already in the closure, so this costs nothing.
  environment.systemPackages = [app];

  # The password
  # ------------
  # One password for everybody, kept as an scrypt hash. Set it on the server:
  #
  #      sudo mkdir -p /etc/calendar
  #      printf '%s' 'the password' | calendar-server hash-password \
  #        | sudo tee /etc/calendar/pw.hash >/dev/null
  #      sudo chmod 0400 /etc/calendar/pw.hash
  #      sudo systemctl restart calendar
  #
  # The plaintext only ever passes through the pipe -- `hash-password` reads
  # stdin so it never appears in a file or on a command line. It does land in
  # your shell history, though, same caveat as split and todo.
  #
  # Changing the password is rewriting that file and restarting. Existing
  # sessions survive it -- they live in the database. To log every device out
  # too, clear the session table:
  #
  #      sudo nix run nixpkgs#sqlite -- /var/lib/calendar/calendar.db 'DELETE FROM sessions;'
  #
  # Backups: the database and the push keys. Everyone's appointments are the
  # thing here that cannot be rebuilt from the flake:
  #
  #      sudo nix run nixpkgs#sqlite -- /var/lib/calendar/calendar.db \
  #        ".backup '/root/calendar-$(date +%F).db'"
  #      sudo cp /var/lib/calendar/vapid.json /root/

  # Behind the shared wildcard cert -- see ./web.nix. useACMEHost, not
  # enableACME: there is one cert for the whole domain and this vhost only
  # borrows it.
  #
  # The PWA bits (manifest, service worker, icons) are served by the app
  # itself, so nothing from ./icons.nix is needed here.
  services.nginx.virtualHosts."calendar.buggly.de" = {
    useACMEHost = "buggly.de";
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${port}";
      # No websockets. Live updates are server-sent events on /api/stream;
      # the server answers those with `X-Accel-Buffering: no`, so nginx passes
      # them through unbuffered, and a ping every 25 s stays well inside
      # nginx's 60 s read timeout.
    };
  };
}

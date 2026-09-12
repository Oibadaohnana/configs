# Shared expenses, split between friends.
#
# Served over HTTPS at https://split.buggly.de -- nginx terminates TLS with the
# shared *.buggly.de cert and proxies to the loopback port below, on the same
# terms as todo.nix and makinglist.nix.
#
# One password for everyone who is in on the ledger. That is the design rather
# than a shortcut: the people using this already share rent and holidays, so
# the door is there to keep the internet out, not to keep them apart. Who spent
# what is recorded per person inside the app, where it is a fact about the
# money and not a credential.
#
# Before this serves anything, the password hash has to exist: the unit fails
# on a box where /etc/split/pw.hash is missing. See "The password" below.
#
# Moving the pin to newer work is `splitupdate`, then `bsyss` -- the same two
# steps as the games, the list and the recipes.
{
  pkgs,
  split,
  ...
}: let
  app = split.packages.${pkgs.stdenv.hostPlatform.system}.default;
  # 8787 is bobby-dangling, 8788 is worms-whup, 8789 is todo, 8790 is
  # makinglist, 8791 is bank-bobbery.
  port = "8792";
  # Root-owned, outside the state directory: the service reads it through
  # systemd's credential mechanism before it drops privileges, so the running
  # process never has permission to open the file itself.
  hashFile = "/etc/split/pw.hash";
in {
  systemd.services.split = {
    description = "Shared expenses, split between friends";
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target"];

    environment = {
      # Loopback only -- nginx is the public face and the only thing that can
      # reach this port. Binding publicly would put the login form back on the
      # open internet without a certificate in front of it.
      SPLIT_HOST = "127.0.0.1";
      SPLIT_PORT = port;
      # StateDirectory below creates and owns this path.
      SPLIT_DB = "/var/lib/split/split.db";

      # On, and it has to be: nginx serves this over HTTPS only, and a Secure
      # cookie is the point of doing so -- without it the session cookie rides
      # along on any plain-HTTP request that slips past the redirect.
      SPLIT_SECURE_COOKIE = "1";

      # No SPLIT_PASSWORD_HASH_FILE here on purpose. The hash arrives as the
      # systemd credential below, which the service finds via
      # CREDENTIALS_DIRECTORY -- `%d` is not expanded inside Environment=, so
      # naming the path here would hand the process a string it cannot use.
    };

    serviceConfig = {
      ExecStart = "${app}/bin/split-server";
      Restart = "on-failure";
      LoadCredential = "pwhash:${hashFile}";
      # No account to create or clean up; the ledger lands in /var/lib/split.
      DynamicUser = true;
      StateDirectory = "split";

      # It parses form input from whoever reaches it -- lock it down the same
      # way the game servers are.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      # No AF_UNIX: a single Rust binary with no child process and no IPC, so
      # the two internet families are all it ever opens.
      RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
      SystemCallFilter = ["@system-service"];
      # A few thousand expenses and their SQLite page cache. Orders of
      # magnitude more than it can use, and still small enough that a leak
      # kills the unit rather than the box.
      MemoryMax = "128M";
    };
  };

  # On PATH so the password can be set without hunting for the store path. The
  # binary is already in the closure, so this costs nothing.
  environment.systemPackages = [app];

  # The password
  # ------------
  # One password for everybody, kept as an Argon2 hash. Set it on the server:
  #
  #      sudo mkdir -p /etc/split
  #      printf '%s' 'the password' | split-server hash-password \
  #        | sudo tee /etc/split/pw.hash >/dev/null
  #      sudo chmod 0400 /etc/split/pw.hash
  #      sudo systemctl restart split
  #
  # The plaintext only ever passes through the pipe -- `hash-password` reads
  # stdin so it never appears in a file or on a command line. It does land in
  # your shell history, though -- this zsh sets HIST_IGNORE_ALL_DUPS but not
  # HIST_IGNORE_SPACE, so clear it afterwards if that matters to you.
  #
  # Changing the password is rewriting that file and restarting. Existing
  # sessions survive it -- they live in the database, not in the hash. To boot
  # everyone out too, clear the session table -- deleting the database would
  # take every receipt with it. sqlite3 is not installed here, so borrow one:
  #
  #      sudo nix run nixpkgs#sqlite -- /var/lib/split/split.db 'DELETE FROM sessions;'
  #
  # Backups are one file. Months of somebody else's money is the thing on this
  # box that cannot be rebuilt from the flake, so this is the line worth a
  # cron job:
  #
  #      sudo nix run nixpkgs#sqlite -- /var/lib/split/split.db \
  #        ".backup '/root/split-$(date +%F).db'"

  # Behind the shared wildcard cert -- see ./web.nix. useACMEHost, not
  # enableACME: there is one cert for the whole domain and this vhost only
  # borrows it.
  #
  # The PWA bits ride along on this: the manifest and the service worker are
  # served by the app itself under `/`, and the icons the manifest names come
  # from ./icons.nix, which merges its own locations into this same vhost.
  services.nginx.virtualHosts."split.buggly.de" = {
    useACMEHost = "buggly.de";
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${port}";
      # No websockets here; the app is plain form posts and redirects.
    };
  };
}

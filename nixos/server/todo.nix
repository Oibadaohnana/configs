# Personal to-do list.
#
# Served over HTTPS at https://todo.baggly.de -- nginx terminates TLS with the
# shared *.baggly.de cert and proxies to the loopback port below. The login
# form no longer crosses the network in clear text, so the password here is an
# ordinary secret again rather than an effectively public one.
#
# Before this serves anything, the password hash has to exist: the unit fails
# on a box where /etc/todo/pw.hash is missing. See "The password" below.
#
# Moving the pin to newer work is `todoupdate`, then `bsyss` -- the
# same two steps as the games.
{
  pkgs,
  todo,
  ...
}: let
  app = todo.packages.${pkgs.stdenv.hostPlatform.system}.default;
  # 8787 is bobby-dangling, 8788 is worms-whup.
  port = "8789";
  # Root-owned, outside the state directory: the service reads it through
  # systemd's credential mechanism before it drops privileges, so the running
  # process never has permission to open the file itself.
  hashFile = "/etc/todo/pw.hash";
in {
  systemd.services.todo = {
    description = "Personal to-do list";
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target"];

    environment = {
      # Loopback only -- nginx is the public face and the only thing that can
      # reach this port. Binding publicly would put the login form back on the
      # open internet without a certificate in front of it.
      TODO_HOST = "127.0.0.1";
      TODO_PORT = port;
      # StateDirectory below creates and owns this path.
      TODO_DB = "/var/lib/todo/todo.db";

      # On, and it has to be: nginx serves this over HTTPS only, and a Secure
      # cookie is the point of doing so -- without it the session cookie rides
      # along on any plain-HTTP request that slips past the redirect.
      TODO_SECURE_COOKIE = "1";

      # No TODO_PASSWORD_HASH_FILE here on purpose. The hash arrives as the
      # systemd credential below, which the service finds via
      # CREDENTIALS_DIRECTORY -- `%d` is not expanded inside Environment=, so
      # naming the path here would hand the process a string it cannot use.
    };

    serviceConfig = {
      ExecStart = "${app}/bin/todo-server";
      Restart = "on-failure";
      LoadCredential = "pwhash:${hashFile}";
      # No account to create or clean up; the list lands in /var/lib/todo.
      DynamicUser = true;
      StateDirectory = "todo";

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
      # A text list and its SQLite page cache. This is orders of magnitude more
      # than it can use, and still small enough that a leak kills the unit
      # rather than the box.
      MemoryMax = "128M";
    };
  };

  # On PATH so the password can be set without hunting for the store path. The
  # binary is already in the closure, so this costs nothing.
  environment.systemPackages = [app];

  # The password
  # ------------
  # One password, kept as an Argon2 hash. Set it on the server:
  #
  #      sudo mkdir -p /etc/todo
  #      printf '%s' 'the password' | todo-server hash-password \
  #        | sudo tee /etc/todo/pw.hash >/dev/null
  #      sudo chmod 0400 /etc/todo/pw.hash
  #      sudo systemctl restart todo
  #
  # The plaintext only ever passes through the pipe -- `hash-password` reads
  # stdin so it never appears in a file or on a command line. It does land in
  # your shell history, though -- this zsh sets HIST_IGNORE_ALL_DUPS but not
  # HIST_IGNORE_SPACE, so clear it afterwards if that matters to you.
  #
  # Changing the password is rewriting that file and restarting. Existing
  # sessions survive it -- they live in the database, not in the hash. To boot
  # them too, clear the session table -- deleting the database would take the
  # list with it. sqlite3 is not installed here, so borrow one:
  #
  #      sudo nix run nixpkgs#sqlite -- /var/lib/todo/todo.db 'DELETE FROM sessions;'

  # Behind the shared wildcard cert -- see ../server/web.nix. useACMEHost, not
  # enableACME: there is one cert for the whole domain and this vhost only
  # borrows it.
  services.nginx.virtualHosts."todo.baggly.de" = {
    useACMEHost = "baggly.de";
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${port}";
      # No websockets here; the app is plain form posts and redirects.
    };
  };
}

# Personal to-do list.
#
# Served on plain HTTP at http://45.129.182.102:8789 -- deliberately, and with
# eyes open. There is no domain yet and so no certificate, which means the
# login form posts the password in clear text to anyone on the path. That is a
# considered trade: the list holds nothing worth protecting, and a tunnel for
# every phone was more friction than the contents justify.
#
# The one thing that follows from it: whatever password is in /etc/todo/pw.hash
# should be used for nothing else, because it is effectively public.
#
# The vhost at the bottom is the way out. When we own a domain -- zaggl.fun is
# a friend's, see ../server/domain-setup.md -- uncomment it, set HOST back to
# 127.0.0.1, drop the firewall line, and this becomes ordinary HTTPS.
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
      # Public, not loopback -- there is no nginx in front while there is no
      # certificate to put there. This is the line that changes back when the
      # vhost below is uncommented.
      TODO_HOST = "0.0.0.0";
      TODO_PORT = port;
      # StateDirectory below creates and owns this path.
      TODO_DB = "/var/lib/todo/todo.db";

      # Off, and it has to be: a Secure cookie is only stored by a browser over
      # HTTPS (localhost aside), so leaving this on over plain HTTP means the
      # login appears to succeed and then bounces straight back to the form,
      # forever. Turn it back on with the vhost.
      TODO_SECURE_COOKIE = "0";

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


  # Open only while the list is reached directly. This line goes away with the
  # vhost below: once nginx is in front, 443 is the only port anybody needs.
  # Same shape as worms-whup, and temporary for the same reason.
  networking.firewall.allowedTCPPorts = [8789];

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

  # Waiting on a domain of our own. zaggl.fun is a friend's -- bobby-dangling
  # sits on it as a favour -- so this does not get a subdomain there. See
  # ../server/domain-setup.md for the records to create once we have one.
  #
  # When todo.<ourdomain> points here, uncomment this and put the real name in.
  # Three things move with it, all in this file: TODO_HOST back to 127.0.0.1,
  # TODO_SECURE_COOKIE back to "1", and the firewall line deleted. web.nix
  # already has 443 open and ACME set up, so nothing outside this file changes.
  #
  # services.nginx.virtualHosts."todo.example.com" = {
  #   enableACME = true;
  #   forceSSL = true;
  #   locations."/" = {
  #     proxyPass = "http://127.0.0.1:${port}";
  #     # No websockets here; the app is plain form posts and redirects.
  #   };
  # };
}

# The LAN game shelf, with shared up- and downvotes.
#
# Served over HTTPS at https://gtp.buggly.de -- nginx terminates TLS with the
# shared *.buggly.de cert and proxies to the loopback port below, on the same
# terms as todo.nix, makinglist.nix and split.nix.
#
# One password for the whole group, like split: the door keeps the internet
# out, not the friends apart. Each person types their name at login and votes
# under it; sessions last 400 days, so a browser stays logged in.
#
# Before this serves anything, the password hash has to exist: the unit fails
# on a box where /etc/gtp/pw.hash is missing. See "The password" below.
#
# Moving the pin to newer work is `gtpupdate`, then `bsyss` -- the same two
# steps as the games, the list and the recipes.
{
  pkgs,
  gtp,
  ...
}: let
  app = gtp.packages.${pkgs.stdenv.hostPlatform.system}.default;
  # 8787 bobby-dangling, 8788 worms-whup, 8789 todo, 8790 makinglist, 8791
  # bank-bobbery, 8792 split, 8793 bims, 8794 grimgobber's door with its eight
  # lobbies on 8795-8802 -- so the first free one is past those.
  port = "8803";
  # Root-owned, outside the state directory: the service reads it through
  # systemd's credential mechanism before it drops privileges, so the running
  # process never has permission to open the file itself.
  hashFile = "/etc/gtp/pw.hash";
in {
  systemd.services.gtp = {
    description = "LAN game shelf with shared votes";
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target"];

    environment = {
      # Loopback only -- nginx is the public face and the only thing that can
      # reach this port.
      GTP_HOST = "127.0.0.1";
      GTP_PORT = port;
      # StateDirectory below creates and owns this path.
      GTP_DB = "/var/lib/gtp/gtp.db";
      # nginx serves this over HTTPS only, so the session cookie is Secure.
      GTP_SECURE_COOKIE = "1";
      # No GTP_PASSWORD_HASH_FILE on purpose: the hash arrives as the systemd
      # credential below, found via CREDENTIALS_DIRECTORY -- `%d` is not
      # expanded inside Environment=.
    };

    serviceConfig = {
      ExecStart = "${app}/bin/gtp-server";
      Restart = "on-failure";
      LoadCredential = "pwhash:${hashFile}";
      # No account to create or clean up; the votes land in /var/lib/gtp.
      DynamicUser = true;
      StateDirectory = "gtp";

      # It parses input from whoever reaches it -- locked down like the rest.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
      SystemCallFilter = ["@system-service"];
      # A few hundred vote rows. Small enough that a leak kills the unit
      # rather than the box.
      MemoryMax = "128M";
    };
  };

  # On PATH so the password can be set without hunting for the store path.
  environment.systemPackages = [app];

  # The password
  # ------------
  # One password, kept as an Argon2 hash. Set it on the server:
  #
  #      sudo mkdir -p /etc/gtp
  #      printf '%s' 'the password' | gtp-server hash-password \
  #        | sudo tee /etc/gtp/pw.hash >/dev/null
  #      sudo chmod 0400 /etc/gtp/pw.hash
  #      sudo systemctl restart gtp
  #
  # The plaintext only passes through the pipe, but it does land in shell
  # history -- clear it afterwards if that matters to you.
  #
  # Changing the password is rewriting that file and restarting. Existing
  # sessions survive it; to log everyone out as well:
  #
  #      sudo nix run nixpkgs#sqlite -- /var/lib/gtp/gtp.db 'DELETE FROM sessions;'

  services.nginx.virtualHosts."gtp.buggly.de" = {
    useACMEHost = "buggly.de";
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${port}";
      # No websockets; a page, a form and two JSON endpoints.
    };
  };
}

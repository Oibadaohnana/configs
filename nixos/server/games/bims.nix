# Bims. Shaped like worms-whup rather than the browser games: the game is a
# desktop binary people already have, and what runs here is only the relay
# that introduces the players to each other and passes bytes between them.
# The world itself is simulated on every player's own machine, the host's
# being the clock (`crates/app/src/net.rs` in the game), so nothing on this
# box knows what a ship is and nothing here needs rebuilding when one
# changes -- only `crates/wire`, the protocol, is shared, and a change to
# *that* is a protocol bump both ends refuse to mismatch.
#
# Unlike worms-whup it sits behind nginx from the start: the shipped client
# dials `wss://bims.buggly.de` (`wire::DEFAULT_SERVER`), so TLS ends here
# and the relay listens on loopback like the other games.
#
# Moving the pin to newer work is `bimsupdate`, then `bsyssl` -- the same two
# steps as the other games.
{
  pkgs,
  bims,
  ...
}: let
  relay = bims.packages.${pkgs.stdenv.hostPlatform.system}.bims-server;
  # 8787 bobby-dangling, 8788 worms-whup, 8789 todo, 8790 makinglist,
  # 8791 bank-bobbery. `wire::DEFAULT_PORT` in the game says the same.
  port = "8792";
in {
  systemd.services.bims = {
    description = "Bims relay";
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target"];

    environment = {
      # Loopback only -- nginx is the public face. Upstream would otherwise
      # bind every interface, which would expose the port past the vhost.
      HOST = "127.0.0.1";
      PORT = port;
    };

    serviceConfig = {
      ExecStart = "${relay}/bin/bims-server";
      Restart = "on-failure";
      # Nothing is written down: rooms live in memory and die with the
      # process. No state directory, and no account to create or clean up.
      DynamicUser = true;

      # Parses untrusted input from the open internet -- lock it down.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      # No AF_UNIX: there is no child process and no IPC pipe, so the relay
      # only ever needs the two internet families.
      RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
      SystemCallFilter = ["@system-service"];
      # A room is four peers and the frames in flight between them; the
      # biggest thing that ever crosses is a few megabytes. 256M is far
      # more than it can use and still small enough that a leak takes the
      # relay down rather than the box.
      MemoryMax = "256M";
    };
  };

  # bims.buggly.de. The wildcard DNS record already answers for it, so
  # this vhost is the whole of what the game needs, and the wildcard cert in
  # ../web.nix already covers it -- no DNS edit, no cert order.
  #
  # proxyWebsockets is not optional -- the whole game runs over the socket.
  # The game pings every ten seconds and the relay reaps a socket silent for
  # forty-five, but a lobby waiting on a fourth player is idle traffic all
  # the same, so the proxy timeouts are lifted well past nginx's sixty.
  services.nginx.virtualHosts."bims.buggly.de" = {
    useACMEHost = "buggly.de";
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${port}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
      '';
    };
  };
}

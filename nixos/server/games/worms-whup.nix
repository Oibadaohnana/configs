# Worms Whup. Unlike Bobby Dangling there is nothing to serve: the game is a
# desktop binary people already have, and what runs here is only the relay that
# introduces them to each other and passes bytes between them. The match itself
# is simulated on whichever machine opened the room.
#
# So there is no CLIENT_DIR, no static files, and nothing on this box that
# needs rebuilding when a weapon changes -- the relay never learns what a
# gamemode is. See `net/src/lib.rs` in the game for why that split is drawn
# where it is.
{
  pkgs,
  worms-whup,
  ...
}: let
  ww = worms-whup.packages.${pkgs.stdenv.hostPlatform.system}.default;
  port = "8788";
in {
  systemd.services.worms-whup = {
    description = "Worms Whup relay";
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target"];

    environment = {
      # Bound publicly rather than on loopback, which is the one place this
      # differs from bobby-dangling: the game is a native client talking
      # WebSocket to a bare address, and shipped copies have that address
      # compiled in. The domain and cert exist now -- see the vhost below for
      # why the move still waits on a client release.
      HOST = "0.0.0.0";
      PORT = port;
    };

    serviceConfig = {
      ExecStart = "${ww}/bin/worms-whup-server";
      Restart = "on-failure";
      # Nothing is written down: rooms live in memory and die with the process.
      # No state directory, and no account to create or clean up.
      DynamicUser = true;

      # Parses untrusted input from the open internet -- lock it down.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      # No AF_UNIX: unlike the node game there is no child process and no IPC
      # pipe, so the relay only ever needs the two internet families.
      RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
      SystemCallFilter = ["@system-service"];
      # A room is a handful of peers and a few kilobytes of queued frames.
      # 256M is far more than it can use and still small enough that a leak
      # takes the relay down rather than the box.
      MemoryMax = "256M";
    };
  };

  # Open only while the relay is reached directly. This line goes away with the
  # vhost below: once nginx is in front, 443 is the only port anybody needs.
  networking.firewall.allowedTCPPorts = [8788];

  # Left as it is on purpose. buggly.de has a wildcard record so the name
  # already resolves, and the cert would be ordered automatically -- but
  # flipping this is not only a server change: the shipped client has
  # `net.server` baked in, so the relay has to keep answering on the bare
  # address until every copy out there has been updated. Uncomment this, set
  # HOST back to 127.0.0.1, drop the firewall line, and point the client at
  # `wss://whup.buggly.de` in the same release. `proxyWebsockets` is the whole
  # of what the relay needs from nginx; there is no static half to split off.
  #
  # services.nginx.virtualHosts."whup.buggly.de" = {
  #   useACMEHost = "buggly.de";
  #   forceSSL = true;
  #   locations."/" = {
  #     proxyPass = "http://127.0.0.1:${port}";
  #     proxyWebsockets = true;
  #   };
  # };
}

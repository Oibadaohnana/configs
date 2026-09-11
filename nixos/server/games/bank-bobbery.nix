# Bank Bobbery. Shaped like bobby-dangling rather than worms-whup: one Node
# process serves the built client, the level editor and the game WebSocket on a
# single port, so nginx proxies one upstream with no static/ws split.
#
# Not imported yet -- server_configuration.nix and flake.nix both need a line
# adding, and the flake input needs a repo to point at. See the block at the
# bottom of this file for the exact two edits.
{
  pkgs,
  bank-bobbery,
  ...
}: let
  bb = bank-bobbery.packages.${pkgs.stdenv.hostPlatform.system}.default;
  # 8787 bobby-dangling, 8788 worms-whup, 8789 todo, 8790 makinglist.
  port = "8791";
in {
  systemd.services.bank-bobbery = {
    description = "Bank Bobbery game server";
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target"];

    environment = {
      # Loopback only -- nginx is the public face. Upstream would otherwise
      # bind every interface, which would expose the port past the vhost.
      HOST = "127.0.0.1";
      PORT = port;

      # The package's own maps/ lives in the store and is read-only. Without
      # this the server falls back to $XDG_DATA_HOME, which under DynamicUser
      # + ProtectHome is not somewhere anything survives a restart. Built-in
      # maps are copied in on first start; maps saved from the in-browser
      # editor land here and persist.
      BB_MAPS_DIR = "/var/lib/bank-bobbery/maps";
    };

    serviceConfig = {
      ExecStart = "${bb}/bin/bankbobbery";
      Restart = "on-failure";
      DynamicUser = true;
      StateDirectory = "bank-bobbery";

      # Parses untrusted input from the open internet -- lock it down.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      # Only the two internet families. Verified by running the server under
      # exactly this filter: unlike bobby-dangling there is no tsx child and no
      # IPC pipe, so no AF_UNIX. AF_NETLINK is not here either -- the startup
      # banner used to call os.networkInterfaces(), which opens a netlink
      # socket and threw EAFNOSUPPORT under this line; the server now treats
      # that listing as optional and carries on.
      RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
      SystemCallFilter = ["@system-service"];
      # A room is a 96x72 map, ~27 NPCs and a handful of players; snapshots are
      # a few KB each and nothing accumulates between rounds. 512M is far more
      # than it should ever touch, and small enough that a leak kills the game
      # rather than the box.
      MemoryMax = "512M";
    };
  };

  # bank.buggly.de. The wildcard DNS record already answers for it,
  # so this vhost is the whole of what the game needs, and the wildcard
  # cert in ../web.nix already covers it -- no DNS edit, no cert order.
  #
  # proxyWebsockets is not optional -- the whole game runs over the socket, and
  # without it the page loads and then sits on "Reconnecting...".
  services.nginx.virtualHosts."bank.buggly.de" = {
    useACMEHost = "buggly.de";
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${port}";
      proxyWebsockets = true;
      # The map arrives as one ~26 KB frame and snapshots stream at 20 Hz;
      # the default 60s proxy_read_timeout would cut an idle lobby loose.
      extraConfig = ''
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
      '';
    };
  };
}
#
# ---------------------------------------------------------------------------
# Wiring, once github.com/Oibadaohnana/bankbobbery exists (same account, so the
# github_serverssh key already reaches it):
#
#   flake.nix, in inputs:
#     bank-bobbery = {
#       url = "git+ssh://git@github.com/Oibadaohnana/bankbobbery?ref=main";
#       inputs.nixpkgs.follows = "nixpkgs";
#     };
#
#   flake.nix, in nixosConfigurations."server":
#     specialArgs = { inherit (inputs) bobby-dangling worms-whup todo makinglist bank-bobbery; };
#
#   server_configuration.nix, in imports:
#     ./server/games/bank-bobbery.nix
#
# Then bump it the same way as the others: `nix flake update bank-bobbery`,
# then `bsyss`.
# ---------------------------------------------------------------------------


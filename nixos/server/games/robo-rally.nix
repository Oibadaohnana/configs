# Robo Rally. The upstream server serves the built client AND the game
# WebSocket on one port (apps/server/src/main.ts), so nginx just proxies one
# upstream -- no static/ws split.
{
  pkgs,
  robo-rally,
  ...
}: let
  rr = robo-rally.packages.${pkgs.stdenv.hostPlatform.system}.default;
  port = "8787";
in {
  systemd.services.robo-rally = {
    description = "Robo Rally game server";
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target"];

    environment = {
      # Loopback only -- nginx is the public face. Upstream defaults to
      # 0.0.0.0, which would expose 8787 past the vhost.
      HOST = "127.0.0.1";
      PORT = port;
      CLIENT_DIR = "${rr}/share/robo-rally/web";
      NODE_ENV = "production";
      # RR_OPEN unset = no browser tab; headless box has none to open.
    };

    serviceConfig = {
      ExecStart = "${rr}/bin/robo-rally-server";
      Restart = "on-failure";
      # No account to create or clean up; state lands in /var/lib/robo-rally.
      DynamicUser = true;
      StateDirectory = "robo-rally";

      # Parses untrusted input from the open internet -- lock it down.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      # AF_UNIX: tsx CLI/child IPC pipe -- EAFNOSUPPORT at startup without it.
      RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
      SystemCallFilter = ["@system-service"];
      MemoryMax = "512M";
    };
  };

  # serverName comes from the attribute name. enableACME orders the cert and
  # wires the .well-known challenge; forceSSL adds the :80 -> :443 redirect.
  # No explicit listen list: forceSSL filters it to ssl entries, so a
  # port-80-only list would leave the vhost bound to nothing. The module
  # default already covers 0.0.0.0 and [::0] on both 80 and 443.
  services.nginx.virtualHosts."robo.zaggl.fun" = {
    default = true;
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${port}";
      # The entire game runs over WS. Without this the page loads and then
      # silently never connects.
      proxyWebsockets = true;
    };
  };
}

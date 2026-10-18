# Grimgobber (Bank Bobbery, the Rust one) at grim.buggly.de. Shaped like
# worms-whup rather than the browser games: the game is a desktop binary, and
# it speaks plain UDP (renet), which nginx does not proxy -- so there is no
# vhost and no TLS, and the firewall opens the ports instead.
#
# One process here is the front door (`--serve`, door.rs in the game): it
# answers "where is lobby SCARE" and "open me a new one", and runs each lobby
# as a child game server on a port of its own. SCARE always runs; a lobby a
# player opens gets a random code and closes itself after ten minutes empty.
#
# Moving the pin to newer work is `grimupdate`, then `bsyssl` -- the same two
# steps as the other games. Players need the same version: the door turns an
# older game away with "update it".
{
  pkgs,
  grimgobber,
  ...
}: let
  # The headless build: no GPU or windowing libraries in its closure.
  gg = grimgobber.packages.${pkgs.stdenv.hostPlatform.system}.grimgobber-server;
  # UDP, not the TCP of the others (8787 bobby-dangling ... 8793 bims): the
  # door on 8794, `net::PORT` in the game and what its title asks, and its
  # eight lobbies on the ports right above it (SCARE on the first).
  door = 8794;
  lobbies = 8;
in {
  systemd.services.grimgobber = {
    description = "Grimgobber door and lobbies";
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target"];

    serviceConfig = {
      # Bound on every interface on purpose: the game dials the bare UDP
      # ports, and nothing sits in front of them.
      ExecStart = "${gg}/bin/grimgobber --serve ${toString door}";
      Restart = "on-failure";
      # Nothing is written down: lobbies live in memory and die with the
      # process. No state directory, and no account to create or clean up.
      DynamicUser = true;

      # Parses untrusted input from the open internet -- lock it down.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      # The lobbies are child processes (execve is in @system-service), but
      # they share no pipe or socket with the door, so no AF_UNIX.
      RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
      SystemCallFilter = ["@system-service"];
      # The whole cgroup, children included: a lobby server sits near 60M, so
      # eight of them and the door stay well under this, and a leak kills the
      # game rather than the box.
      MemoryMax = "1G";
    };
  };

  networking.firewall.allowedUDPPortRanges = [
    {
      from = door;
      to = door + lobbies;
    }
  ];
}

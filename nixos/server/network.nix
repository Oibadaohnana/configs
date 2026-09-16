# IPv6. Not in ./hardware/server.nix because that file is generated.
#
# Why this is needed at all: the zone has had an AAAA record on both @ and *
# since before this module existed, but the box had no global IPv6 address, so
# every name on buggly.de published an address that answered nothing. Browsers
# hid it -- Happy Eyeballs races v6 against v4 and falls back in ~300ms -- so
# it showed up as a slight delay on first connection rather than an outage.
#
# The cause is Netcup's router advertisement, which dhcpcd logs on every
# renewal:
#
#     ens3: fe80::1: no longer a default router (lifetime = 0)
#
# A router lifetime of 0 means "do not use me as a default router". dhcpcd
# obeys it and drops the route, and nothing configures an address. The gateway
# itself is fine -- fe80::1 answers pings and carries the VRRP virtual MAC
# 00:00:5e:00:02:02 -- so the link works and only autoconfiguration is broken.
# This is why Netcup documents IPv6 as a static configuration.
{...}: {
  networking = {
    # Deliberately the EUI-64 address SLAAC used to derive, back when the RA
    # still carried a usable lifetime: it is exactly what the existing AAAA
    # records already point at, so fixing this needed no DNS change. The
    # interface identifier matches ens3's link-local, fe80::147c:bdff:fe1f:d8fc
    # -- that is where the value comes from, not from a Netcup panel field.
    interfaces.ens3.ipv6.addresses = [
      {
        address = "2a03:4000:47:f45:147c:bdff:fe1f:d8fc";
        prefixLength = 64;
      }
    ];

    # Link-local, so it needs the interface named explicitly -- fe80::1 is
    # ambiguous on its own and the route cannot be installed without a scope.
    defaultGateway6 = {
      address = "fe80::1";
      interface = "ens3";
    };
  };

  # IPv4 is untouched: dhcpcd keeps its lease on ens3 exactly as before, which
  # is also why a mistake here cannot lock anyone out -- ssh arrives over v4.
}

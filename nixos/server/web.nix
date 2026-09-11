# Shared public entry point. Every web game is an nginx vhost onto a loopback
# port -- games never bind a public interface themselves, so adding one costs
# no firewall change.
#
# One wildcard certificate covers the lot, so a new game is a vhost and nothing
# else: no DNS edit, no cert order, no rate-limit risk from a burst of new
# subdomains.
{config, ...}: {
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedTlsSettings = true;
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "bennywuest@posteo.com";

    # The one cert. Vhosts reference it with `useACMEHost = "baggly.de"` rather
    # than `enableACME` -- the two are mutually exclusive, and enableACME would
    # order a separate per-name cert over HTTP-01.
    certs."baggly.de" = {
      # Cert name, and so also `domain`, must not contain a "*" -- the acme
      # module builds systemd unit names from it. The wildcard rides along as
      # an extra SAN instead. The apex needs naming explicitly: *.baggly.de
      # matches www but never baggly.de itself.
      extraDomainNames = ["*.baggly.de"];

      # Let's Encrypt will not issue a wildcard over HTTP-01 -- there is no
      # single hostname to fetch a challenge file from -- so DNS-01 is the only
      # route, and lego needs API access to write the TXT record itself. The
      # value is a fresh token every renewal, which is why this cannot be a
      # record placed by hand.
      #
      # Cloudflare rather than Netcup because baggly.de sits on Netcup's
      # CloudDNS, and lego's netcup provider only speaks the older CCP DNS API
      # (ccp.netcup.net/run/webservice/...) -- a CloudDNS key cannot
      # authenticate against it. The domain stays registered at Netcup; only
      # the nameservers point at Cloudflare.
      #
      # `dnsProvider` also has to be the *only* challenge set here -- the
      # module asserts exactly one of dnsProvider/webroot/listenHTTP/s3Bucket,
      # and nginx only injects a webroot for enableACME vhosts, so useACMEHost
      # everywhere keeps that assertion satisfied.
      dnsProvider = "cloudflare";
      # Rendered by ./secrets.nix from the sops-encrypted token in this repo --
      # nothing to place on the server by hand. Scoped "Edit zone DNS" on baggly.de.
      environmentFile = config.sops.templates."cloudflare-acme.env".path;

      # Without this nginx cannot read the key: acme certs default to group
      # "acme", and the nginx module only auto-sets the group for enableACME
      # vhosts, never for useACMEHost ones.
      group = "nginx";

      # Cloudflare serves a fresh TXT record almost immediately, so the default
      # self-check -- lego queries the zone's own nameservers until the record
      # shows up -- costs seconds. Left on deliberately: a failure here is a
      # real problem, not impatience.
      dnsPropagationCheck = true;
    };
  };

  # 22 comes from services.openssh.openFirewall. 80 stays open after TLS: it
  # carries the redirect to https that forceSSL installs. It is no longer
  # needed for ACME -- validation is DNS-01 now -- but browsers still arrive
  # on it from typed and old links.
  networking.firewall.allowedTCPPorts = [80 443];
}

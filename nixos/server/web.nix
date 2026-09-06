# Shared public entry point. Every web game is an nginx vhost onto a loopback
# port -- games never bind a public interface themselves, so adding one costs
# no firewall change.
{...}: {
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedTlsSettings = true;
  };

  # Shared by every vhost that sets enableACME. Per-game certs are separate
  # orders, so one game's rate-limit trouble cannot block another's renewal.
  security.acme = {
    acceptTerms = true;
    defaults.email = "bennywuest@posteo.com";
  };

  # 22 comes from services.openssh.openFirewall. 80 stays open after TLS: it
  # carries the ACME http-01 challenge and the redirect to https.
  networking.firewall.allowedTCPPorts = [80 443];
}

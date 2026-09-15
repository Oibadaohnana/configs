# File drop -- https://share.buggly.de. One shared password, one directory.
#
# Deliberately not an app: nginx serves the directory directly, so there is no
# service to keep running, no database, and nothing to update. Putting a file
# in /var/lib/share is the entire publishing step. See "Uploading" below.
#
# Access is one HTTP basic-auth credential that everybody uses -- no accounts,
# nothing per-person. Changing it is ../../scripts/share-password.sh, which
# rewrites the sops secret; the username is not a secret and is only there
# because the browser prompt has a field for it.
{config, ...}: let
  domain = "buggly.de";
  # Under /var/lib rather than /srv so it sits with the other service state
  # and is covered by whatever backs that up. Created by the tmpfiles rule
  # below, not by hand -- a missing directory makes nginx 404 every request
  # with nothing in the log to explain why.
  root = "/var/lib/share";
in {
  # 0750 benji:nginx -- benji owns it so uploads are a plain scp with no sudo,
  # nginx is the group so the worker can read what lands there. Not 0755:
  # every other local user would otherwise get the files for free, which is
  # the one thing the password is meant to prevent.
  systemd.tmpfiles.rules = [
    "d ${root} 0750 benji nginx -"
  ];

  services.nginx.virtualHosts."share.${domain}" = {
    # Same wildcard cert as everything else -- see web.nix. No DNS record to
    # add either: *.buggly.de already resolves here.
    useACMEHost = domain;
    forceSSL = true;
    inherit root;

    # Server level, not inside a location: nginx inherits auth_basic downward,
    # so this covers the listing and the files and anything added later. Put
    # it in `locations."/"` instead and the regex location below -- a sibling,
    # not a child -- would serve videos with no password at all.
    extraConfig = ''
      auth_basic "buggly share";
      auth_basic_user_file ${config.sops.secrets."share-htpasswd".path};
    '';

    locations."/".extraConfig = ''
      autoindex on;
      autoindex_exact_size off;
      autoindex_localtime on;
    '';

    # Browsers play a linked .mp4 instead of saving it, which reads as a broken
    # page to anyone who just wanted the file. Content-Disposition turns the
    # click back into a download.
    #
    # Scoped to media extensions and not applied at server level on purpose:
    # the autoindex listing is itself a response, and attaching the header
    # there would download the directory listing as a file.
    locations."~* \\.(mp4|mkv|mov|webm|avi|m4v|zip|7z|iso|pdf)$".extraConfig = ''
      add_header Content-Disposition "attachment";
    '';
  };
}

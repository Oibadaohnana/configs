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

    # Two independent secrets on the download path: an unguessable directory
    # name *and* the password. Either one alone is useless, so a link forwarded
    # into a group chat does not hand over the file.
    #
    # This location briefly carried `auth_basic off` -- a pure capability URL,
    # nothing to type -- because the password is what blocked the first share:
    # nginx logged `user "Friends"` and `user "friends "` six times in five
    # minutes, a phone keyboard capitalising the first letter and autocorrect
    # appending a space. Basic auth cannot ignore the username, since it is
    # half the credential in the protocol, so ../../scripts/share-password.sh
    # now writes an htpasswd entry for each of those manglings against the one
    # hash. That keeps the password without the footgun.
    #
    # The token is the directory name *under* /dl/, created on the server and
    # deliberately kept out of this repo, which is pushed to GitHub:
    #
    #     t=$(head -c9 /dev/urandom | base32 | tr -d = | tr 'A-Z' 'a-z')
    #     mkdir -p /var/lib/share/dl/$t && echo $t
    #
    # 9 bytes of /dev/urandom is 72 bits, so guessing one is not a threat that
    # needs rate limiting. /dl/ itself is still a dead end -- autoindex off
    # makes it 403 rather than listing the tokens, which is the whole reason
    # they sit one level down instead of directly under the root.
    #
    # `^~` rather than a plain prefix, and this is the part that is easy to
    # get wrong: in nginx a matching regex location beats a plain prefix
    # location, so /dl/<token>/film.mp4 would otherwise be served by the media
    # block above and this block would never run at all -- which is why
    # Content-Disposition has to be repeated here instead of inherited. It
    # matters less now that both paths end up password-protected, but it still
    # decides which block sets the download header.
    locations."^~ /dl/".extraConfig = ''
      autoindex off;
      add_header Content-Disposition "attachment";
    '';
  };
}

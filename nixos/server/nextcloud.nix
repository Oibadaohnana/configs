# Personal cloud -- https://cloud.buggly.de. Documents, synced with the
# Nextcloud desktop and phone apps, or uploaded through the web page.
#
# Unlike ./share.nix this *is* an app: PHP-FPM, PostgreSQL and Redis, all set
# up by the NixOS module. Files live in /var/lib/nextcloud/data.
{
  config,
  pkgs,
  ...
}: let
  domain = "buggly.de";
  hostName = "cloud.${domain}";
in {
  services.nextcloud = {
    enable = true;
    # Major versions cannot be skipped on upgrade: going from 35 to 37 means
    # deploying 36 first and letting it migrate, then 37.
    package = pkgs.nextcloud35;
    inherit hostName;
    # nginx adds the TLS below; this makes Nextcloud generate https:// links.
    https = true;

    database.createLocally = true;
    configureRedis = true;

    config = {
      dbtype = "pgsql";
    };

    # Also PHP's memory_limit -- the module points both at this one value, so
    # it cannot be 20G on a box with 2 GB of RAM. The apps upload in chunks
    # anyway, so a single file larger than this still gets through.
    maxUploadSize = "1G";
    phpOptions."session.upload_progress.enabled" = "0";

    # The module's defaults are sized for 4 GB of RAM (120 workers). This box
    # has 2 GB shared with postgres, redis and the games, so keep it small --
    # for one person a handful of workers is plenty.
    poolSettings = {
      "pm" = "dynamic";
      "pm.max_children" = "8";
      "pm.start_servers" = "2";
      "pm.min_spare_servers" = "1";
      "pm.max_spare_servers" = "3";
      "pm.max_requests" = "500";
    };

    settings = {
      default_phone_region = "DE";
      # Background jobs that are heavy (cleanup, previews) run from 01:00 UTC
      # for four hours instead of whenever.
      maintenance_window_start = 1;
      # The disk is the tight part: 59G total, with /var/lib/share and the nix
      # store already on it. Without these, old file versions and the trash
      # bin can quietly grow to half the free space. "auto, 30" = delete after
      # 30 days, or sooner if space runs out.
      trashbin_retention_obligation = "auto, 30";
      versions_retention_obligation = "auto, 30";
    };
  };

  # The module creates this vhost (php-fpm, headers, upload size); this only
  # adds TLS. Same wildcard cert as everything else -- see ./web.nix. No DNS
  # record to add: *.buggly.de already resolves here.
  services.nginx.virtualHosts.${hostName} = {
    useACMEHost = domain;
    forceSSL = true;
  };

  # Backups: /var/lib/nextcloud/data (the files) plus the database:
  #
  #      sudo -u nextcloud pg_dump nextcloud > /root/nextcloud-$(date +%F).sql
  #
  # Both together -- the files without the database lose shares, versions and
  # the account, and the database without the files is useless.
}

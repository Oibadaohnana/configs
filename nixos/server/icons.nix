# Site icons -- one per vhost, rendered here and served by nginx rather than by
# the app behind it. The apps live in five separate repos and none of them ships
# an icon, so doing this upstream would be five changes and five releases to get
# one consistent set. Here it is one entry in `sites` below.
#
# A browser asks for /favicon.ico on its own for any page that does not name an
# icon, so a proxied app needs no change at all: `= /favicon.ico` is an
# exact-match location and beats the `/` proxy without touching anything else
# the vhost serves.
#
# The 192, 512 and maskable PNGs are here for the same reason: a web app
# manifest has to name icons at those sizes before a browser will offer to
# install the site, and split, todo and rezepte are all PWAs. Their manifests
# name these paths; the manifest itself is served by each app, because it
# carries that app's name and colours and nothing here knows those.
{
  pkgs,
  lib,
  ...
}: let
  # The near-black the landing page sits on. Glyphs are cut out of the accent in
  # this, and not the other way round: a coloured tile stays visible on a light
  # tab strip and a dark one, a dark tile disappears into the second.
  ink = "#11131a";

  # 64 units square, and nothing thinner than about 4.5 of them -- these get
  # looked at at 16px, where a 3-unit stroke falls under one pixel and greys
  # out. A different hue per site: the shape is what says "one of mine", the
  # colour is what tells two pinned tabs apart.
  sites = {
    "buggly.de" = rec {
      accent = "#ffc857"; # the landing page's own accent
      # A bug, for buggly. The wing seam is one line in the background colour
      # rather than two half-shells -- one element instead of two paths.
      glyph = ''
        <g stroke-width="5.5">
          <line x1="27" y1="17" x2="20" y2="8"/>
          <line x1="37" y1="17" x2="44" y2="8"/>
          <line x1="19" y1="31" x2="8" y2="27"/>
          <line x1="18" y1="39" x2="6" y2="39"/>
          <line x1="19" y1="47" x2="8" y2="52"/>
          <line x1="45" y1="31" x2="56" y2="27"/>
          <line x1="46" y1="39" x2="58" y2="39"/>
          <line x1="45" y1="47" x2="56" y2="52"/>
        </g>
        <circle cx="32" cy="20" r="8.5"/>
        <ellipse cx="32" cy="39" rx="15" ry="17"/>
        <line x1="32" y1="26" x2="32" y2="55" stroke="${accent}" stroke-width="4"/>
      '';
    };

    "bobby.buggly.de" = {
      accent = "#59c2ff";
      # Rope and weight, mid-swing. Reads as a pendulum at 16px, which is the
      # whole of what the name promises.
      glyph = ''
        <path d="M32 7 C 32 24, 41 27, 45 36" fill="none" stroke-width="6"/>
        <circle cx="45" cy="46" r="11"/>
      '';
    };

    "bank.buggly.de" = {
      accent = "#4ade80";
      # A money bag: tie band and body. A currency symbol on the body was the
      # other option and it closes up to a smudge at 16px.
      glyph = ''
        <rect x="21" y="13" width="22" height="8" rx="4"/>
        <path d="M27 22 C 15 28, 8 40, 14 49 C 18 56, 46 56, 50 49 C 56 40, 49 28, 37 22 Z"/>
      '';
    };

    "todo.buggly.de" = {
      accent = "#a78bfa";
      # A tick, and nothing else. The one glyph here that survives any size.
      glyph = ''
        <path d="M16 34 L27 45 L48 20" fill="none" stroke-width="9" stroke-linejoin="round"/>
      '';
    };

    "split.buggly.de" = {
      accent = "#fb923c";
      # A coin split in two, the halves pulled apart along the cut. Two
      # half-discs and a gap: the offset is what makes it read as "divided"
      # rather than as a circle with a line through it at 16px.
      glyph = ''
        <path d="M29 6 A 24 24 0 0 0 29 54 Z"/>
        <path d="M35 10 A 24 24 0 0 1 35 58 Z"/>
      '';
    };

    "rezepte.buggly.de" = {
      accent = "#fb7185";
      # A pot: knob, lid, two handles, tapered body. Crossed cutlery is the
      # usual choice and it is two thin strokes, which is exactly what does not
      # survive 16px.
      glyph = ''
        <rect x="26" y="9" width="12" height="8" rx="4"/>
        <rect x="8" y="19" width="48" height="10" rx="5"/>
        <rect x="2" y="32" width="13" height="10" rx="5"/>
        <rect x="49" y="32" width="13" height="10" rx="5"/>
        <path d="M13 31 L51 31 L47 51 Q 46 56 41 56 L23 56 Q 18 56 17 51 Z"/>
      '';
    };
  };

  source = site:
    pkgs.writeText "icon.svg" ''
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
      <rect width="64" height="64" rx="14" fill="${site.accent}"/>
      <g fill="${ink}" stroke="${ink}" stroke-linecap="round">
      ${site.glyph}
      </g>
      </svg>
    '';

  # The same tile with square corners and the glyph pulled into the middle 80%.
  # Android masks a `purpose: "maskable"` icon to whatever shape the launcher
  # uses -- a circle on most, a squircle on others -- and crops everything
  # outside that safe zone. An icon drawn to the edge loses its corners, and a
  # tile that rounds its own corners gets rounded twice with a pale sliver
  # between the two radii. split, todo and rezepte each name one in their
  # manifest; it is built for every site because it costs one more resvg call.
  maskableSource = site:
    pkgs.writeText "icon-maskable.svg" ''
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
      <rect width="64" height="64" fill="${site.accent}"/>
      <g fill="${ink}" stroke="${ink}" stroke-linecap="round" transform="translate(6.4 6.4) scale(0.8)">
      ${site.glyph}
      </g>
      </svg>
    '';

  # ICO and not PNG: /favicon.ico is what a browser fetches unprompted, and ICO
  # is the one format all of them accept there. The container holds a single
  # 32x32 PNG -- legal since Vista and what every generator emits now -- so the
  # file is 22 bytes of header and then that PNG.
  render = name: site:
    pkgs.runCommand "icons-${name}" {nativeBuildInputs = [pkgs.resvg];} ''
      mkdir $out
      cp ${source site} $out/favicon.svg
      resvg -w 32 -h 32 $out/favicon.svg icon.png
      # 180px is what iOS pins to a home screen. Nothing else asks for it.
      resvg -w 180 -h 180 $out/favicon.svg $out/apple-touch-icon.png

      # A web app manifest has to name a 192 and a 512 before Chrome will offer
      # to install the site at all, and the 512 is what it puts on the splash
      # screen. split, todo and rezepte all name them.
      resvg -w 192 -h 192 $out/favicon.svg $out/icon-192.png
      resvg -w 512 -h 512 $out/favicon.svg $out/icon-512.png
      resvg -w 512 -h 512 ${maskableSource site} $out/icon-maskable.png

      # printf twice over: the inner one writes the literal text \xNN, the outer
      # one turns that into the byte. Little-endian, four bytes.
      le32() {
        printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
          $(($1 & 255)) $((($1 >> 8) & 255)) $((($1 >> 16) & 255)) $((($1 >> 24) & 255)))"
      }
      {
        printf '\x00\x00\x01\x00\x01\x00'          # one image follows
        printf '\x20\x20\x00\x00\x01\x00\x20\x00'  # 32x32, one plane, 32bpp
        le32 $(stat -c %s icon.png)                # how long the PNG is
        le32 22                                    # ...and where it starts
        cat icon.png
      } > $out/favicon.ico
    '';

  # `root` on an exact-match location means nginx serves <store path>/<that
  # name> and never consults the proxy or the vhost root.
  served = dir:
    lib.genAttrs [
      "= /favicon.ico"
      "= /favicon.svg"
      "= /apple-touch-icon.png"
      "= /icon-192.png"
      "= /icon-512.png"
      "= /icon-maskable.png"
    ] (_: {
      root = dir;
      # Nothing here changes between releases, and a 404-less icon fetch on
      # every page load is not worth a log line.
      extraConfig = ''
        access_log off;
        expires 7d;
      '';
    });
in {
  # Merged into the vhosts defined in ./landing.nix, ./todo.nix,
  # ./makinglist.nix, ./split.nix and ./games/*.nix -- the module system joins the two
  # definitions. A name here with no vhost of its own would quietly create a
  # plain-HTTP one, so these must match the serverNames over there exactly.
  services.nginx.virtualHosts =
    lib.mapAttrs (name: site: {locations = served (render name site);}) sites;
}

# buggly.de on benji-server

Registered at Netcup, DNS served by Cloudflare, one wildcard certificate over
the lot. Adding a game is a vhost in `server/games/` and nothing else -- no DNS
edit, no cert order.

> `zaggl.fun` is a friend's and no longer used. `bobby.zaggl.fun` still
> resolves here until they remove the record, but nothing answers for it: that
> vhost is now `bobby.buggly.de`. Old links break.

Server addresses:

- IPv4 `45.129.182.102`
- IPv6 `2a03:4000:47:f45:147c:bdff:fe1f:d8fc`

The `/22` on the IPv4 address is the subnet prefix length. It describes which
neighbours are local to the server's NIC. It is **not** part of a DNS record --
records take the bare address.

## Why DNS is at Cloudflare

A wildcard certificate is only issued against a DNS-01 challenge -- there is no
single hostname to serve an HTTP-01 challenge file from -- so the ACME client
must write a TXT record into the zone itself, over an API.

Netcup put buggly.de on **CloudDNS**, their newer DNS system. lego, the ACME
client NixOS drives, only has a provider for Netcup's *older* CCP API
(`ccp.netcup.net/run/webservice/...`); a CloudDNS key cannot authenticate
against it and nobody has written a CloudDNS provider. So the nameservers point
at Cloudflare, which lego supports properly. The domain itself stays registered
at Netcup -- only the NS records moved.

Beware: lego *does* ship a provider called `clouddns`. That is ClouDNS.net, an
unrelated company. It is not Netcup CloudDNS.

### The DENIC trap, if the nameservers ever move again

`.de` verifies that the target nameservers **already answer authoritatively**
for the zone before it will delegate. Point Netcup at nameservers whose zone
does not exist yet -- or, as happened here, at a zone for a differently spelled
domain -- and the change is rejected with:

> Der Nameserver '...' antwortet nicht auf allen seinen IP-Adressen autoritativ
> für diese Domain.

The message is accurate. Check before retrying:

    dig +norecurse @guy.ns.cloudflare.com buggly.de SOA

Wants `status: NOERROR` and `flags: qr aa`. `REFUSED` means that nameserver has
no zone for the name you typed.

## 1. Records at Cloudflare

| Type | Name | Value                                  | Proxy    |
|------|------|----------------------------------------|----------|
| A    | `@`  | `45.129.182.102`                       | DNS only |
| AAAA | `@`  | `2a03:4000:47:f45:147c:bdff:fe1f:d8fc` | DNS only |
| A    | `*`  | `45.129.182.102`                       | DNS only |
| AAAA | `*`  | `2a03:4000:47:f45:147c:bdff:fe1f:d8fc` | DNS only |

**DNS only -- the grey cloud, never the orange one.** Proxied records put
Cloudflare in the traffic path, terminating TLS itself and dropping idle
WebSocket connections after 100 seconds. The games run entirely over
WebSockets, so a quiet lobby would die on its own.

**The wildcard does not cover the apex.** `*.buggly.de` matches
`www.buggly.de` and `bobby.buggly.de` but never `buggly.de` itself, which is
why the `@` pair is there as well. There is no separate `www` record.

Nameservers at Netcup, both required:

    guy.ns.cloudflare.com
    violet.ns.cloudflare.com

No glue records. Glue is only for nameservers inside the domain they serve;
these live in `cloudflare.com`, so a resolver looks them up normally. Supplying
IPs for them is malformed and DENIC may reject it.

### CAA

Cloudflare adds none by default. If one appears and does not list
`letsencrypt.org`, issuance fails with an unhelpful error.

## 2. The Cloudflare API token

Already done, and it lives in this repo encrypted -- there is nothing to create
on the server.

The token is a scoped one: **My Profile -> API Tokens -> Create Token -> "Edit
zone DNS"**, with Zone Resources set to `Include → Specific zone → buggly.de`.
That template grants `Zone → DNS → Edit` and `Zone → Zone → Read`, exactly what
lego needs. Not the Global API Key -- that is account-wide.

A token's scope can be edited later without changing its value, so pointing an
existing token at a different zone does not mean re-entering it here.

To change the token:

    sops nixos/server/secrets/cloudflare.yaml

from the repo root. sops decrypts into `$EDITOR` and re-encrypts on save; the
plaintext never touches the disk. Commit it and `bsyssl`.

How it fits together:

- `.sops.yaml` names two recipients: the laptop's age key
  (`~/.config/sops/age/keys.txt`) and benji-server's SSH **host** key. Nothing
  was installed on the server -- sops-nix reads
  `/etc/ssh/ssh_host_ed25519_key` at activation.
- `server/secrets.nix` renders `/run/secrets/rendered/cloudflare-acme.env` as
  `CF_DNS_API_TOKEN=…`, the shape lego wants. `/run` is tmpfs, so the plaintext
  only ever exists in RAM.
- `server/web.nix` points `environmentFile` at that path.

The copy of the secret in the nix store stays ciphertext, so **building and
deploying from any machine needs no key at all** -- only editing does.

**Back up `~/.config/sops/age/keys.txt`.** It is the only key that can edit
these files.

A reinstall gives the server a new host key, so afterwards:

    ssh-keyscan -t ed25519 45.129.182.102 | ssh-to-age   # the new recipient
    # update .sops.yaml, then:
    sops updatekeys nixos/server/secrets/cloudflare.yaml

Restoring `/etc/ssh/ssh_host_ed25519_key` with the box avoids that entirely.

## 3. Deploy

    bsyssl

`bsyssl` builds the closure on the laptop and pushes it; `bsyss` builds on the
server itself, which is slower on a box this size.

nginx starts immediately on a self-signed placeholder -- the acme module always
generates one -- so a browser warning right after the rebuild means the real
certificate has not arrived yet, not that something is broken. Watch it land:

    systemctl status acme-buggly.de.service
    journalctl -u acme-buggly.de.service -f

lego writes a TXT record at `_acme-challenge.buggly.de`, waits for Cloudflare's
nameservers to serve it, tells Let's Encrypt to look, then deletes it. Seconds.

A cert covering both `buggly.de` and `*.buggly.de` gets two separate
challenges, both at that same name, live at once. lego handles it; worth
knowing only if you ever watch the records go by.

Renewal runs on a daily timer (`Persistent=yes`, so it catches up after
downtime) and reloads nginx itself when a new cert lands.

## 4. Verify

    dig +short buggly.de A
    dig +short buggly.de AAAA
    dig +short anything-at-all.buggly.de A      # wildcard: same answer

    curl -sI https://buggly.de/        | head -1
    curl -sI https://www.buggly.de/    | head -1
    curl -sI https://bobby.buggly.de/  | head -1
    curl -sI -6 https://buggly.de/     | head -1

All four must return `HTTP/2 200`. The `-6` one is the one that gets forgotten.

Check what the certificate actually covers:

    openssl s_client -connect buggly.de:443 -servername buggly.de </dev/null 2>/dev/null \
      | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'

Expect `DNS:buggly.de, DNS:*.buggly.de`.

## Adding a game later

1. A module under `server/games/`, with the service on a loopback port and a
   vhost:

       services.nginx.virtualHosts."thegame.buggly.de" = {
         useACMEHost = "buggly.de";   # not enableACME -- they are exclusive
         forceSSL = true;
         locations."/" = {
           proxyPass = "http://127.0.0.1:${port}";
           proxyWebsockets = true;    # if the game uses a socket
         };
       };

2. An entry in `server/landing.nix` so it shows up on the front page.
3. An entry in `server/icons.nix`, keyed by the same vhost name, so the tab gets
   an icon rather than a blank page sheet. See "Icons" below.
4. The import in `server_configuration.nix`.

Ports in use: 8787 bobby-dangling, 8788 worms-whup, 8789 todo, 8790 makinglist,
8791 bank-bobbery, 8792 bims (the relay; the desktop game dials
`wss://bims.buggly.de`, so it sits behind nginx from the start).

No DNS record and no certificate work -- the wildcards already cover it.

## Icons

`server/icons.nix` renders one icon per vhost -- a coloured tile with a dark
glyph cut out of it, a different hue each so two pinned tabs tell apart -- and
nginx serves it at three exact-match paths:

    /favicon.ico            32x32, a PNG inside an ICO container
    /favicon.svg            the source, for anything that would rather scale it
    /apple-touch-icon.png   180x180, what iOS pins to a home screen

The apps behind the proxy need no change for this. A browser asks for
`/favicon.ico` on its own for any page that names no icon, and `= /favicon.ico`
is an exact-match location, so it wins over the `/` proxy without disturbing
anything else the vhost serves.

**Unless the page does name one.** todo and makinglist carried

    link rel="icon" href="data:,";

in `src/views.rs` -- an empty icon, added back when nothing here answered for
`/favicon.ico` and every page load logged a 404. That line suppresses the
automatic request, so those two stay blank until the replacement ships:
`todoupdate` / `makinglistupdate`, then `bsyssl`. The other three pick their
icon up on the next `bsyssl` alone.

Changing an icon is the glyph in `server/icons.nix` and `bsyssl`. They go out
with `expires 7d`, so a browser that has already seen one keeps it for up to a
week; a hard reload or a private window shows the new one at once.

## What a reinstall has to redo

The Cloudflare token is not on this list -- it rides along in the repo. What
remains are two password hashes, read as systemd credentials:

- `/etc/todo/pw.hash` -- see `server/todo.nix`
- `/etc/makinglist/pw.hash` -- see `server/makinglist.nix`

Their units fail to start without them. Both could move into sops the same way
the token did; until they do, this is the list.

# baggly.de on benji-server

The domain is registered at Netcup; DNS is served by Cloudflare; one wildcard
certificate covers every subdomain. Adding a game is a vhost in `server/games/`
and nothing else -- no DNS edit, no cert order.

> `zaggl.fun` is a friend's and no longer used. `bobby.zaggl.fun` still
> resolves here until they remove the record, but nothing answers for it: that
> vhost is now `bobby.baggly.de`. Old links break.

Server addresses:

- IPv4 `45.129.182.102`
- IPv6 `2a03:4000:47:f45:147c:bdff:fe1f:d8fc`

The `/22` on the IPv4 address is the subnet prefix length. It describes which
neighbours are local to the server's NIC. It is **not** part of a DNS record --
records take the bare address.

## Why DNS lives at Cloudflare

Netcup put `baggly.de` on **CloudDNS**, their newer DNS system. lego -- the
ACME client NixOS drives -- only has a provider for Netcup's *older* CCP API
(`ccp.netcup.net/run/webservice/...`), and a CloudDNS API key cannot
authenticate against it. Nobody has written a CloudDNS provider for lego.

Without a working DNS API there is no DNS-01 challenge, and without DNS-01
there is no wildcard certificate -- Let's Encrypt will not issue `*.baggly.de`
over HTTP-01, because there is no single hostname to fetch a challenge file
from.

So the nameservers point at Cloudflare, which lego supports properly. The
domain itself stays registered at Netcup; only the NS records moved.

Beware: lego *does* ship a provider called `clouddns`. That is ClouDNS.net, an
unrelated company. It is not Netcup CloudDNS.

## 1. Records at Cloudflare

| Type | Name | Value                                  | Proxy    |
|------|------|----------------------------------------|----------|
| A    | `@`  | `45.129.182.102`                       | DNS only |
| AAAA | `@`  | `2a03:4000:47:f45:147c:bdff:fe1f:d8fc` | DNS only |
| A    | `*`  | `45.129.182.102`                       | DNS only |
| AAAA | `*`  | `2a03:4000:47:f45:147c:bdff:fe1f:d8fc` | DNS only |

**DNS only -- the grey cloud, never the orange one.** Proxied records put
Cloudflare in the traffic path, which terminates TLS itself and drops idle
WebSocket connections after 100 seconds. The games run entirely over
WebSockets, so a quiet lobby would die on its own.

**The wildcard does not cover the apex.** `*.baggly.de` matches
`www.baggly.de` and `bobby.baggly.de` but never `baggly.de` itself, which is
why the `@` pair is there as well. There is no separate `www` record -- the
wildcard answers for it.

Both address families matter. Let's Encrypt prefers AAAA when it connects, so
a missing or dead IPv6 address is worse than none at all.

### Nameservers at Netcup

Two, and both are required -- DENIC will not delegate to one:

    guy.ns.cloudflare.com
    violet.ns.cloudflare.com

(Cloudflare assigns a pair per zone; check the dashboard if these ever change.)

### The DENIC pre-delegation check

`.de` is unusual: DENIC verifies the nameservers already answer authoritatively
for the zone **before** it will create the domain. Register too soon after
setting up the Cloudflare zone and Netcup rejects the order with

> Der Nameserver '...' antwortet nicht auf allen seinen IP-Adressen autoritativ
> für diese Domain.

That is a timing failure, not a configuration one. Confirm the zone is live,
then retry:

    dig +norecurse @guy.ns.cloudflare.com baggly.de SOA

Wants `status: NOERROR` and `flags: qr aa` -- the `aa` is the authoritative bit
DENIC is looking for. Check `violet` too.

### CAA

Cloudflare does not add one by default. If a CAA record ever appears and does
not list `letsencrypt.org`, issuance fails with an unhelpful error.

## 2. The Cloudflare API token

In the Cloudflare dashboard: profile menu -> **My Profile** -> **API Tokens**
-> **Create Token** -> the **"Edit zone DNS"** template. It grants
`Zone → DNS → Edit` and `Zone → Zone → Read`, which is exactly what lego needs.
Under Zone Resources pick `Include → Specific zone → baggly.de`.

Not the Global API Key further down that page -- that one is account-wide and
can do anything. API tokens are on the free plan.

The token lives in this repo, encrypted. Put it in from the repo root:

    sops nixos/server/secrets/cloudflare.yaml

That decrypts into `$EDITOR`, you replace the placeholder value, and it
re-encrypts on save -- the plaintext never lands on disk. Then commit it like
any other file and `bsyssl`. There is nothing to create on the server.

How it fits together:

- `.sops.yaml` names the two recipients: the laptop's age key
  (`~/.config/sops/age/keys.txt`) and benji-server's SSH **host** key. The
  server needs nothing installed -- sops-nix reads
  `/etc/ssh/ssh_host_ed25519_key` at activation.
- `server/secrets.nix` decrypts the token and renders
  `/run/secrets/rendered/cloudflare-acme.env` as
  `CF_DNS_API_TOKEN=…`, which is the shape lego wants.
- `server/web.nix` points `environmentFile` at that path.

`/run` is a tmpfs, so the decrypted token never touches the disk on the server
either.

**Back up `~/.config/sops/age/keys.txt`.** It is the only key that can edit
these files. Lose it and the server can still read them, but you cannot change
them -- you would recreate the secret and re-encrypt.

A reinstall gives the server a *new* host key, so afterwards the secrets must
be re-encrypted to it:

    ssh-keyscan -t ed25519 45.129.182.102 | ssh-to-age   # the new recipient
    # update .sops.yaml, then:
    sops updatekeys nixos/server/secrets/cloudflare.yaml

Restoring `/etc/ssh/ssh_host_ed25519_key` with the box avoids that entirely.
## 3. Rebuild

    bsyssl

`bsyssl` builds the closure on the laptop and pushes it; `bsyss` builds on the
server itself, which is slower on a box this size.

nginx starts immediately on a self-signed placeholder -- the acme module always
generates one -- so a browser warning right after the rebuild means the real
certificate has not arrived yet, not that something is broken. Watch it land:

    systemctl status acme-baggly.de.service
    journalctl -u acme-baggly.de.service -f

DNS-01 is slower than HTTP-01: lego writes a TXT record at
`_acme-challenge.baggly.de`, waits for the zone's own nameservers to serve it,
tells Let's Encrypt to look, then deletes it. Seconds on Cloudflare.

A cert covering both `baggly.de` and `*.baggly.de` gets two separate
challenges, both at that same name, live at once. lego handles this; it is only
worth knowing if you ever watch the records go by.

## 4. Verify

    dig +short baggly.de A
    dig +short baggly.de AAAA
    dig +short anything-at-all.baggly.de A      # wildcard: same answer

    curl -sI https://baggly.de/        | head -1
    curl -sI https://www.baggly.de/    | head -1
    curl -sI https://bobby.baggly.de/  | head -1
    curl -sI -6 https://baggly.de/     | head -1

All four must return `HTTP/2 200`. The `-6` one is the one that gets forgotten.
`curl` validates the certificate itself, so a clean exit is also proof the
chain is real.

Check what the certificate actually covers:

    openssl s_client -connect baggly.de:443 -servername baggly.de </dev/null 2>/dev/null \
      | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'

Expect `DNS:baggly.de, DNS:*.baggly.de`.

## Adding a game later

1. A module under `server/games/`, with the service on a loopback port and a
   vhost:

       services.nginx.virtualHosts."thegame.baggly.de" = {
         useACMEHost = "baggly.de";   # not enableACME -- they are exclusive
         forceSSL = true;
         locations."/" = {
           proxyPass = "http://127.0.0.1:${port}";
           proxyWebsockets = true;    # if the game uses a socket
         };
       };

2. An entry in `server/landing.nix` so it shows up on the front page.
3. The import in `server_configuration.nix`.

Ports in use: 8787 bobby-dangling, 8788 worms-whup, 8789 todo, 8790 makinglist,
8791 bank-bobbery.

No DNS record and no certificate work -- the wildcards already cover it. A
subdomain with no vhost of its own lands on the front page, which is the
`default = true` in `server/landing.nix`.

## What a reinstall has to redo

The Cloudflare token is no longer on this list -- it rides along in the repo.
What remains are the two password hashes, both read as systemd credentials:

- `/etc/todo/pw.hash` -- see `server/todo.nix`
- `/etc/makinglist/pw.hash` -- see `server/makinglist.nix`

Their units fail to start without them. Both could move into sops the same way
the token did; until they do, this is the list.

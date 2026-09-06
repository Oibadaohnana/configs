# Pointing a domain at benji-server

Server addresses:

- IPv4 `45.129.182.102`
- IPv6 `2a03:4000:47:f45:147c:bdff:fe1f:d8fc`

The `/22` on the IPv4 address is the subnet prefix length. It describes which
neighbours are local to the server's NIC. It is **not** part of a DNS record --
records take the bare address.

## 0. Rebuild first

nginx must answer on both address families before an AAAA record exists, or
IPv6 visitors get a dead site and Let's Encrypt fails validation (it prefers
AAAA). `server/games/robo-rally.nix` listens on `0.0.0.0` and `[::]`, so:

    buildsysserver

Confirm v6 is live:

    curl -sI -6 'http://[2a03:4000:47:f45:147c:bdff:fe1f:d8fc]/' | head -1

## 1. Records at the domain provider

Replace `example.com` with the real domain. `@` means the domain itself; some
providers want that field left blank, or want the full domain typed out. All
three mean the same thing.

| Type | Name  | Value                                  | TTL |
|------|-------|----------------------------------------|-----|
| A    | `@`   | `45.129.182.102`                       | 300 |
| AAAA | `@`   | `2a03:4000:47:f45:147c:bdff:fe1f:d8fc` | 300 |
| A    | `www` | `45.129.182.102`                       | 300 |
| AAAA | `www` | `2a03:4000:47:f45:147c:bdff:fe1f:d8fc` | 300 |

That is the whole minimum: two names, two address families.

The `www` pair can instead be one CNAME named `www` with value `example.com.`
(trailing dot required by most providers). Equivalent; the A/AAAA pair is
marginally faster and never wrong.

TTL 300 while setting up -- a typo costs 5 minutes, not a day. Raise to 3600
once it works.

### CAA

Do not add one. If the provider already created a CAA record and it does not
list `letsencrypt.org`, issuance fails with an unhelpful error. Check, and if
one exists add `0 issue "letsencrypt.org"`.

### Wildcard, once there is a second game

Subdomains per game (`roborally.example.com`, `chess.example.com`) avoid
editing DNS for every new one:

| Type | Name | Value                                  |
|------|------|----------------------------------------|
| A    | `*`  | `45.129.182.102`                       |
| AAAA | `*`  | `2a03:4000:47:f45:147c:bdff:fe1f:d8fc` |

Note a wildcard *certificate* is a separate problem: it needs DNS-01 validation
with a provider API token, where per-subdomain certs work over plain HTTP-01.
Start per-subdomain.

## 2. Verify

    dig +short example.com A
    dig +short example.com AAAA
    curl -sI http://example.com/ | head -1
    curl -sI -6 http://example.com/ | head -1

Both curls must return `HTTP/1.1 200 OK`. The `-6` one is the one that matters.

## 3. Then TLS

Only after the four checks pass. In `server/web.nix`: enable ACME, accept the
Let's Encrypt terms, set an email, add `enableACME` + `forceSSL` to the vhost,
and open port 443 in the firewall.

Two things that are broken on plain HTTP and fixed by this:

- browsers rewrite typed addresses to `https://`, hit the closed port 443, and
  report the site as unreachable
- `navigator.clipboard` only exists in a secure context, so the lobby's copy
  buttons fail (the app catches this -- `Lobby.tsx`, "insecure origin")

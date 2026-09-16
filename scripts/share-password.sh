#!/usr/bin/env bash
#
# share-password.sh — set the password for https://share.buggly.de.
#
# One credential, shared by everyone who gets the link. This rewrites the sops
# secret nixos/server/secrets/share.yaml; nothing takes effect until the server
# is redeployed, so the last line tells you to run bsyssl.
#
# Why this exists rather than `sops nixos/server/secrets/share.yaml`: editing a
# sops file means decrypting it first, which needs the age *private* key --
# and that lives only on the laptop (see ../.sops.yaml). Writing a fresh file
# needs only the public keys, so this works from any machine in the repo.
#
# Usage: ./share-password.sh [username]        (default: fontis)

set -euo pipefail

NIXCFG="${NIXCFG:-$HOME/nixcfg}"
SECRET="$NIXCFG/nixos/server/secrets/share.yaml"
# Not a secret and not a login -- the browser's basic-auth prompt just has a
# field for it, and leaving it blank is not allowed. Tell people the same one.
USER_NAME="${1:-fontis}"

command -v mkpasswd >/dev/null || { echo "mkpasswd not found (pkgs.mkpasswd)" >&2; exit 1; }
command -v sops     >/dev/null || { echo "sops not found (pkgs.sops)" >&2; exit 1; }

read -rsp "Password for '$USER_NAME': " pw1; echo
read -rsp "Again: "                     pw2; echo
[[ "$pw1" == "$pw2" ]] || { echo "They differ." >&2; exit 1; }
[[ -n "$pw1" ]]        || { echo "Empty." >&2; exit 1; }

# bcrypt, not the default: nginx hands anything starting with '$' to crypt(3),
# and libxcrypt on NixOS does $2b$. -s reads the password from stdin so it
# never appears in the process list or in shell history.
hash=$(printf '%s' "$pw1" | mkpasswd -m bcrypt -s)

# --filename-override is what makes sops pick the creation_rule for this path;
# the real input is stdin, which matches nothing in .sops.yaml. Written to a
# temp file first so a failure here leaves the existing secret intact.
# Every mangling a phone keyboard is likely to produce, all sharing the one
# hash. The first share failed on precisely this and nothing else: nginx logged
# `user "Friends" was not found` and `user "friends " was not found` six times
# in five minutes, because autocapitalize raises the first letter and autocorrect
# appends a space, and nginx compares the username byte-for-byte. Basic auth has
# no way to ignore the username -- it is half of the credential in the protocol
# -- so the only fix is to accept what the keyboard actually sends.
#
# The space lands *before* the colon (`fontis :$2b$...`), so it is interior to
# the line, not trailing whitespace a YAML parser might strip.
cap="$(printf '%s' "${USER_NAME:0:1}" | tr '[:lower:]' '[:upper:]')${USER_NAME:1}"
variants=$(for u in "$USER_NAME" "$cap" "$USER_NAME " "$cap "; do
             printf '  %s:%s\n' "$u" "$hash"
           done | sort -u)

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
printf 'share-htpasswd: |\n%s\n' "$variants" \
  | sops --encrypt --input-type yaml --output-type yaml \
         --filename-override "$SECRET" /dev/stdin > "$tmp"
mv "$tmp" "$SECRET"; trap - EXIT

echo
echo "Wrote $SECRET"
echo "Password: the one you just typed"
echo "Accepted usernames (same password for each):"
printf '%s\n' "$variants" | sed 's/:.*//' | sed 's/^  /  [/;s/$/]/'
echo "Deploy it: bsyssl"

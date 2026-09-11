# Encrypted secrets, decrypted on the server at activation time.
#
# The point is that nothing here has to be created by hand on the box. The
# token lives in this repo as ./secrets/cloudflare.yaml, encrypted to two age
# recipients (see ../../.sops.yaml): the laptop's key, so it can still be
# edited, and benji-server's own SSH host key, so the server can read it
# without anything extra being installed. `bsyssl` is the whole deployment.
#
# Editing the token:
#
#     sops nixos/server/secrets/cloudflare.yaml
#
# from the repo root. sops decrypts into $EDITOR and re-encrypts on save; the
# plaintext never touches the disk, and the copy in the nix store stays
# ciphertext -- so building on any machine needs no key at all. Only editing
# does.
#
# The two password hashes -- /etc/todo/pw.hash and /etc/makinglist/pw.hash --
# are the remaining by-hand steps on this box and belong here too; adding them
# is one file plus a few lines below.
{config, ...}: {
  # The host key sshd already generated. Nothing to provision -- it exists
  # before this module ever runs. A reinstall makes a *new* host key, so the
  # secrets need `sops updatekeys` afterwards unless the old key is restored
  # with the box. See ../../.sops.yaml.
  sops.age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];

  sops.secrets."cf-dns-api-token".sopsFile = ./secrets/cloudflare.yaml;

  # lego wants an EnvironmentFile, not a bare value, so the decrypted token is
  # interpolated into one. `sops.placeholder` is substituted at activation, and
  # /run is tmpfs -- the plaintext only ever exists in RAM.
  sops.templates."cloudflare-acme.env".content = ''
    CF_DNS_API_TOKEN=${config.sops.placeholder."cf-dns-api-token"}
  '';
}

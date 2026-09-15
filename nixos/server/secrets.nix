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

  # The share.buggly.de basic-auth credential -- one htpasswd line, shared by
  # everyone who gets the link. Owned by nginx because auth_basic_user_file is
  # read by the worker at request time, not by the master at startup: leave it
  # root-only and every request 500s on a permission error.
  #
  # Set or change it with ../../scripts/share-password.sh. That script writes
  # the file rather than editing it, so it works on a machine without the age
  # private key -- encrypting needs only the public keys in ../../.sops.yaml.
  sops.secrets."share-htpasswd" = {
    sopsFile = ./secrets/share.yaml;
    owner = "nginx";
  };

  # lego wants an EnvironmentFile, not a bare value, so the decrypted token is
  # interpolated into one. `sops.placeholder` is substituted at activation, and
  # /run is tmpfs -- the plaintext only ever exists in RAM.
  sops.templates."cloudflare-acme.env".content = ''
    CF_DNS_API_TOKEN=${config.sops.placeholder."cf-dns-api-token"}
  '';
}

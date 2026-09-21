# The agents overview app (see scripts/agents.sh, which execs it for `agents ui`).
{ lib, rustPlatform }:
rustPlatform.buildRustPackage {
  pname = "agents-ui";
  version = "0.2.0";
  src = lib.cleanSource ./.;
  cargoLock.lockFile = ./Cargo.lock;
  meta.mainProgram = "agents-ui";
}

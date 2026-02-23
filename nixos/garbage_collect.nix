{ pkgs, ... }:
let
  pinnedShell = import ../shells/shell.nix { inherit pkgs; };
in {
  nix.gc = {
    automatic = true;
    dates = "weekly";
    persistent = true;
    options = "--delete-older-than 30d";
  };

  nix.settings.auto-optimise-store = true;

  # Keep the dev shell closure rooted so nix GC does not collect its inputs.
  # mkShell outputs are not valid systemPackages entries, so root it via the
  # system closure instead.
  system.extraDependencies = [ pinnedShell ];
}

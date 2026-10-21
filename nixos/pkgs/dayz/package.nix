{ lib, writers, fzf }:
writers.writePython3Bin "dayz" {
  flakeIgnore = [ "E265" "E501" ];
  makeWrapperArgs = [ "--prefix" "PATH" ":" (lib.makeBinPath [ fzf ]) ];
} (builtins.readFile ./dayz.py)

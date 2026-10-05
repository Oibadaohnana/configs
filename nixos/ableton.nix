{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    wineWow64Packages.stable
    winetricks
    wineasio
    (let
      wineasioDlls = runCommand "wineasio-dlls" { } ''
        for arch in windows unix; do
          ext=dll; [ $arch = unix ] && ext=dll.so
          mkdir -p $out/x86_64-$arch
          for name in wineasio wineasio64; do
            ln -s ${wineasio}/lib/wine/x86_64-$arch/wineasio64.$ext \
              $out/x86_64-$arch/$name.$ext
          done
        done
      '';
    in writeShellScriptBin "ableton" ''
      export WINEPREFIX="''${WINEPREFIX:-$HOME/.wine-ableton}"
      export WINEDLLPATH="${wineasioDlls}"
      export PIPEWIRE_LATENCY="''${PIPEWIRE_LATENCY:-128/48000}"
      rm -f "$WINEPREFIX/dosdevices/z:"
      case "$1" in
        setup)
          wineboot --init
          wine regsvr32 /s wineasio64.dll && echo "WineASIO registered in $WINEPREFIX"
          ;;
        install)
          shift
          case "$1" in
            *.msi) wine msiexec /i "$1" ;;
            *) wine "$1" ;;
          esac
          ;;
        *)
          exe=$(ls "$WINEPREFIX"/drive_c/ProgramData/Ableton/Live\ 10*/Program/Ableton\ Live\ 10*.exe 2>/dev/null | head -1)
          [ -n "$exe" ] || { echo "Live 10 not found in $WINEPREFIX -- run 'ableton install <installer>' first" >&2; exit 1; }
          cd "$WINEPREFIX/drive_c"
          exec wine "$exe" "$@"
          ;;
      esac
    '')
  ];

  services.pipewire.jack.enable = true;
  security.rtkit.enable = true;
}

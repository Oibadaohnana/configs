{ config, pkgs, ... }:

{
  fonts = {
    packages = with pkgs; [
      # Icon glyphs for waybar. symbols-only carries the whole Nerd Font
      # glyph range (Font Awesome, Devicons, Material, Octicons, ...) in the
      # private use area WITHOUT shipping a text face, so it never competes to
      # render normal text -- fontconfig only reaches for it on codepoints no
      # other font covers. This is what the bar's icons actually resolve to.
      nerd-fonts.symbols-only

      # Font Awesome 7. Registers as "Font Awesome 7 Free" / "Font Awesome 7
      # Brands" -- NOT the "FontAwesome" family name that v4-era waybar configs
      # reference, so naming that in CSS still resolves to nothing.
      #
      # Heads up: FA7 Brands maps its brand icons onto the same private-use
      # codepoints as Nerd Fonts but with different artwork, and it wins the
      # fallback for them. That is why the firefox glyph (U+F269) in
      # waybarconfig renders as FA7's mark rather than the Nerd Fonts logo.
      # This is intentional -- keep both packages if you want that look. If you
      # ever want the glyphs to match the nerdfonts.com cheat sheet instead,
      # drop this one line; symbols-only already carries the full FA set.
      font-awesome

      # A patched monospace face, for terminals/editors that want icons inline.
      nerd-fonts.jetbrains-mono

      # Text faces. Noto is what sans-serif already resolved to, so pinning it
      # keeps the bar looking the way it did before icons were added.
      noto-fonts
      noto-fonts-color-emoji
      dejavu_fonts
    ];

    enableDefaultPackages = true;

    fontconfig.defaultFonts = {
      sansSerif = [ "Noto Sans" "Symbols Nerd Font" ];
      serif     = [ "Noto Serif" "Symbols Nerd Font" ];
      monospace = [ "JetBrainsMono Nerd Font" "Symbols Nerd Font" ];
      emoji     = [ "Noto Color Emoji" ];
    };

    # unifont (pulled in by enableDefaultPackages) ships "sample sheet" faces
    # that claim the entire private use area -- the exact range Nerd Font icons
    # live in. They sort ahead of Symbols Nerd Font in fallback and render every
    # icon as a blank box. Rejecting just the sample/CSUR faces hands the PUA
    # back to Nerd Fonts while leaving unifont's real last-resort coverage
    # ("Unifont", "Unifont Upper") intact.
    fontconfig.localConf = ''
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
      <fontconfig>
        <selectfont>
          <rejectfont>
            <pattern><patelt name="family"><string>Unifont Sample</string></patelt></pattern>
            <pattern><patelt name="family"><string>Unifont CSUR</string></patelt></pattern>
            <pattern><patelt name="family"><string>Unifont JP Sample</string></patelt></pattern>
            <pattern><patelt name="family"><string>Unifont T Sample</string></patelt></pattern>
          </rejectfont>
        </selectfont>
      </fontconfig>
    '';
  };
}

# Fonts shipped with Polter

`NotoSansSC-Regular.otf` is the one font the screenshot tool draws with: the
text and number annotations, and the box they are typed in. Both hosts load
this file rather than a system font so that an annotation is the same glyphs
on macOS and on Windows (`dev-docs/poltergeist/screenshot.md`, 9.1).

- **What it is.** Noto Sans SC Regular 2.004, the Simplified Chinese
  region-subset OTF (CFF outlines) from
  <https://github.com/notofonts/noto-cjk>, path `Sans/SubsetOTF/SC/`.
  Unmodified. 8,331,336 bytes.
- **License.** SIL Open Font License 1.1; the text is `OFL.txt`, which is
  installed beside the font.
- **Where it ends up.** `zig build` installs this directory, minus this
  README, to `<prefix>/share/ghostty/polter/fonts/`. That is
  `<resources dir>/polter/fonts/NotoSansSC-Regular.otf` for both hosts: the
  macOS app bundle carries `share/ghostty` as `Contents/Resources/ghostty`,
  and the Windows package ships `share/` whole.
- **What it does not cover.** It is the Simplified Chinese subset: Latin,
  kana and the Han characters Simplified Chinese uses. A character outside
  it -- Hangul, a Han form only Japanese or Traditional Chinese uses -- is
  drawn from a system font, character by character, and that is ordinary
  fallback, not an error. Only the *file* being absent is reported.

`tools/the-annotation-font-ships.py` checks that the file is the one
described here, that the license is beside it, and that the build installs
both.

# PixelKit assets in Drafter

Copied by `app/sync-pixelkit.py` from PixelKit 5.8.0 (`~/Codius/pixelkit`, the design system). Do not edit here:
change the drawing in PixelKit and run the script again. `app/build.sh` copies this folder into the app's Resources;
nothing is loaded from the network.

- `fonts/`: Fixel Text and Fixel Display (MacPaw, SIL Open Font License 1.1, `FIXEL-LICENSE.txt`) and JetBrains Mono
  (JetBrains, SIL Open Font License 1.1, `JETBRAINS-LICENSE.txt`), from `ds/project/fonts/`. The licence allows
  bundling them with software; the fonts are not sold on their own.
- Marks (mic, bookmark, idcard, calendar, bolt, search, translate, pencil, chat, spark, link, waveform, verified, cloud, phone, document, keyboard, layers, cog, bulb, quote, browser, mail, terminal, code, image, pin, people, book, clock) from `ds/project/assets/Marks/marks.json` and line glyphs from
  `ds/project/assets/Glyphs/glyphs.json` are data in `app/PixelArt.swift`.
- `people/`: People avatars (short, bob, person) from `ds/project/assets/People/`, the two sides of a call.
- `themes/`: the built-in themes. `pixel.json` is PixelKit's own look; `coffee`, `saggar` and `benidorm` are its skin
  presets from `tokens.json` (`skins`). The file format is in `docs/themes.md`.
- PixelKit (colours, marks, glyphs) is the author's own design system, MIT like Drafter. Origins and licences of
  every part: `NOTICE.md` at the repository root.

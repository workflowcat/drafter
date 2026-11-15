#!/usr/bin/env python3
"""Refresh what Drafter takes from PixelKit. Generated files are committed; builds never need the PixelKit checkout.

  python3 app/sync-pixelkit.py [<pixelkit checkout>]     (default ~/Codius/pixelkit/.worktrees/pk-5.6, its main)

Writes app/PixelTokens.swift (colours, both themes, from tokens.flat.json), app/PixelArt.swift (marks, line glyphs and
line glyphs as data) and copies the fonts into app/art/ (see app/art/README.md for what came from where).
Never hand-edit the outputs: change the lists below, or the drawing in PixelKit, and run this again.
"""
import json, re, shutil, sys
from pathlib import Path

pk = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / "Codius/pixelkit/.worktrees/pk-5.6"
app = Path(__file__).resolve().parent
flat = json.loads((pk / "tokens.flat.json").read_text())
version = flat["version"]

# colours: Swift name -> token name in tokens.flat.json
COLOURS = {"paper": "paper", "card": "card", "ink": "ink", "muted": "muted", "faint": "faint", "line": "hair",
           "rule": "rule", "controlEdge": "control-edge", "soft": "soft", "key": "key", "keyEdge": "key-edge",
           "primary": "primary", "primaryEdge": "primary-edge", "onPrimary": "on-primary",
           "blue": "blue", "mint": "mint", "violet": "violet", "coral": "coral", "warn": "warn",
           "selected": "selected-bg", "okBg": "ok-bg", "warnBg": "warn-bg", "critBg": "crit-bg", "actionBg": "action-bg",
           "ok": "ok", "crit": "crit"}
# fixed colours (one value in both themes): the strip under the notch
FIXED = {"onCut": "on-cut", "onCutMuted": "on-cut-muted"}
# fonts: Fixel for words, Fixel Display for the few titles, JetBrains Mono for numbers, times and keys
FONTS = ["FixelText-Regular", "FixelText-Medium", "FixelText-SemiBold", "FixelDisplay-SemiBold",
         "JetBrainsMono-Regular", "JetBrainsMono-Medium"]
# 16-grid marks: the kinds of offer and record
MARKS = ["mic", "bookmark", "idcard", "calendar", "bolt", "search", "translate", "pencil", "chat", "spark", "link", "waveform", "verified", "cloud", "phone",
         "document", "keyboard", "layers", "cog", "bulb",
         # the tape (2026-11-14): copied (quote), the source app of a row, pinned (pin: a place pin stands in, PixelKit
         # has no pushpin), the window's corner marks
         "quote", "browser", "mail", "terminal", "code", "image", "pin", "people", "book", "clock"]
# line glyphs: interface (buttons, search, the Claude mark on a setting)
GLYPHS = ["search", "copy", "play", "pause", "folder", "more", "refresh", "close", "filter", "external", "send", "check",
          "chevron-right", "chevron-down", "list", "edit",
          # the tape (2026-11-14, second pass: "a line glyph is interface, a pixel sprite is a thing in a story"): the
          # kinds (copied copy, typed keys, said waves, call phone), the source app of a row, pinned, the window's corners
          "keys", "waves", "phone", "sparkle", "chat", "mail", "globe", "terminal", "file-edit", "calendar", "image", "map",
          "file", "bookmark", "settings", "help", "user", "pin", "arrow-left",
          # the screenshot tool (2026-11-15, look round): the T text mode and the text mark, File in the send-to list
          "text", "download", "plus",
          # the wire round (2026-11-15): a code found in a text
          "hash",
          # the picker (2026-11-15, picker round): remove from history, a link row
          "trash", "link"]
# stand-ins where PixelKit has no line glyph yet (listed as PixelKit gaps in docs/rounds/2026-11-14-tape.md), drawn on
# the same 24 grid with the same stroke
GLYPH_GAPS = {"cloud": '<path d="M7 18.5h10a4 4 0 0 0 .6-7.95A5.5 5.5 0 0 0 7.1 9.6 4.5 4.5 0 0 0 7 18.5z"/>',
              # the screenshot tool (2026-11-15, look round): Tabler outline shapes at 1.5 for the capture pill
              # (region, window, screen), the markup pill (arrow, box, highlight, blur, crop, pin, undo) and the strip
              # (put in, speak) and the send-to list (Clipboard)
              "marquee": '<path d="M4 6a2 2 0 0 1 2-2M10 4h4M18 4a2 2 0 0 1 2 2M20 10v4M20 18a2 2 0 0 1-2 2M14 20h-4M6 20a2 2 0 0 1-2-2M4 14v-4"/>',
              "app-window": '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M6 8h.01M9 8h.01"/>',
              "device-desktop": '<rect x="3" y="4" width="18" height="12" rx="1"/><path d="M7 20h10M9 16v4M15 16v4"/>',
              "arrow-up-right": '<path d="M17 7L7 17M8 7h9v9"/>',
              "square": '<rect x="4" y="4" width="16" height="16" rx="2"/>',
              "highlight": '<path d="M3 19h4L17.5 8.5a2.83 2.83 0 1 0-4-4L3 15v4M12.5 5.5l4 4M4.5 13.5l4 4M21 15v4h-8l4-4z"/>',
              "blur": '<path d="M12 3a9 9 0 0 0 0 18M12 3a9 9 0 0 1 0 18M12 7h6.6M12 11h8.9M12 15h8.4M12 19h4"/>',
              "crop": '<path d="M8 5v10a1 1 0 0 0 1 1h10M5 8h10a1 1 0 0 1 1 1v10"/>',
              "circle-number": '<circle cx="12" cy="12" r="9"/><path d="M10 10l2-2v8"/>',
              "arrow-back-up": '<path d="M9 14l-4-4 4-4M5 10h11a4 4 0 1 1 0 8h-1"/>',
              "corner-down-left": '<path d="M18 6v6a3 3 0 0 1-3 3H5M9 11l-4 4 4 4"/>',
              "microphone": '<rect x="9" y="2" width="6" height="11" rx="3"/><path d="M5 10a7 7 0 0 0 14 0M8 21h8M12 17v4"/>',
              "clipboard": '<path d="M9 5H7a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-2"/><rect x="9" y="3" width="6" height="4" rx="2"/>',
              # the wire round (2026-11-15): things found in a text (money, e-mail)
              "coin": '<circle cx="12" cy="12" r="9"/><path d="M14.8 9a2 2 0 0 0-1.8-1h-2a2 2 0 1 0 0 4h2a2 2 0 1 1 0 4h-2a2 2 0 0 1-1.8-1M12 7v10"/>',
              "at": '<circle cx="12" cy="12" r="4"/><path d="M16 12v1.5a2.5 2.5 0 0 0 5 0V12a9 9 0 1 0-5.5 8.28"/>',
              # the picker (2026-11-15, picker round): Pick parts, a clip's written forms, a link as Markdown
              "scissors": '<circle cx="6" cy="7" r="3"/><circle cx="6" cy="17" r="3"/><path d="M8.6 8.6L19 19M8.6 15.4L19 5"/>',
              "arrows-left-right": '<path d="M21 17H3M6 10L3 7l3-3M3 7h18M18 20l3-3-3-3"/>',
              "markdown": '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 15V9l2 2 2-2v6M14 13l2 2 2-2M16 15V9"/>'}


def rgba(v):
    if v.startswith("#"):
        return v[1:], 1.0
    m = re.fullmatch(r"rgba\((\d+),(\d+),(\d+),([\d.]+)\)", v.replace(" ", ""))
    return "%02x%02x%02x" % tuple(int(x) for x in m.groups()[:3]), float(m[4])


# Every colour job asks the theme in use (Theme.swift, ThemeStore); PixelKit's own values are the fallback when no
# theme file loads.
out = [f"// Generated by app/sync-pixelkit.py from PixelKit {version} (tokens.flat.json). Do not hand-edit.",
       "// Each job asks the theme in use (ThemeStore in Theme.swift); `pixel` holds PixelKit's own values, the fallback.", "import AppKit", "",
       "enum PKColors {"]
for name in COLOURS:
    out.append(f'    static let {name} = ThemeStore.color("{name}")')
out.append("    /// PixelKit's own look, light and dark: job -> (hex, alpha).")
for theme in ("light", "dark"):
    out.append(f"    static let pixel{theme.title()}: [String: (UInt32, CGFloat)] = [")
    for name, key in COLOURS.items():
        h, a = rgba(flat[theme][key])
        out.append(f'        "{name}": (0x{h}, {a}),')
    out.append("    ]")
for name, key in FIXED.items():
    h, a = rgba(flat["fixed"][key])
    out.append(f'    static let {name} = PK.hex(0x{h}, {a})')
out.append("}")
(app / "PixelTokens.swift").write_text("\n".join(out) + "\n")

art = app / "art"
shutil.rmtree(art, ignore_errors=True)
(art / "fonts").mkdir(parents=True)

# themes (2026-11-14): a theme is a PixelKit skin preset (eleven colours per theme, fonts, four corners, edge, shadow),
# read by the app from art/themes/ and data/themes/ (docs/themes.md). pixel is PixelKit's own look: its preset holds
# the eleven colours and, under "tokens", every job's exact value, so nothing is derived for it.
skins = json.loads((pk / "tokens.json").read_text())["skins"]
THEMES = ["coffee", "saggar", "benidorm"]   # vidindeed is a client's offer look: not shipped in a personal app
(art / "themes").mkdir()
rad = json.loads((pk / "tokens.json").read_text())["radius"]
pixel = {"name": "Pixel", "job": "PixelKit's own look: paper, Fixel and JetBrains Mono, keycaps, pixel marks.",
         "fonts": {"display": '"Fixel Display", "Fixel Text", -apple-system, system-ui, sans-serif',
                   "body": '"Fixel Text", -apple-system, system-ui, sans-serif',
                   "mono": '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, monospace'},
         "corners": [int(rad[k].rstrip("px")) for k in "0123"], "edge": {"light": 48, "dark": 34},
         "shadow": flat["shadow"]["shadow-float"], "tokens": {}}
for theme in ("light", "dark"):
    t = flat[theme]
    pixel[theme] = {"ground": t["paper"], "raised": t["card"], "soft": t["soft"], "ink": t["ink"], "quiet": t["muted"],
                    "faint": t["faint"], "accent": t["blue"], "good": t["ok"], "bad": t["crit"], "waiting": t["warn"],
                    "mix": "#14161a" if theme == "light" else "#ffffff"}
    pixel["tokens"][theme] = {name: t[key] for name, key in COLOURS.items()}
# the journal's soft surfaces, radii and motion (soft round, 2026-11-14; docs/themes.md): the same in every built-in theme
SOFT = {"surface": {"light": {"well": 5, "hover": 4.5, "pick": 8.5}, "dark": {"well": 30, "hover": 5, "pick": 9}},
        "radii": {"pane": 12, "card": 10, "row": 8}, "motion": {"fold": 120, "fade": 80}}
pixel.update(SOFT)
(art / "themes/pixel.json").write_text(json.dumps(pixel, indent=1, ensure_ascii=False) + "\n")
for name in THEMES:
    k = {key: v for key, v in skins[name].items() if key not in ("text",)}
    k.update(SOFT)
    (art / f"themes/{name}.json").write_text(json.dumps(k, indent=1, ensure_ascii=False) + "\n")
for f in FONTS:
    shutil.copy(pk / "ds/project/fonts" / f"{f}.woff2", art / "fonts")
for lic in ["FIXEL-LICENSE.txt", "JETBRAINS-LICENSE.txt"]:
    shutil.copy(pk / "site/fonts" / lic, art / "fonts")
# People avatars (24 x 24, exported at 96): the two sides of a call on the tape (pixel sprites: the people are the subject)
PEOPLE = ["short", "bob", "person"]
(art / "people").mkdir()
for f in PEOPLE:
    shutil.copy(pk / "ds/project/assets/People" / f"{f}.png", art / "people")
(art / "README.md").write_text(f"""# PixelKit assets in Drafter

Copied by `app/sync-pixelkit.py` from PixelKit {version} (`~/Codius/pixelkit`, the design system). Do not edit here:
change the drawing in PixelKit and run the script again. `app/build.sh` copies this folder into the app's Resources;
nothing is loaded from the network.

- `fonts/`: Fixel Text and Fixel Display (MacPaw, SIL Open Font License 1.1, `FIXEL-LICENSE.txt`) and JetBrains Mono
  (JetBrains, SIL Open Font License 1.1, `JETBRAINS-LICENSE.txt`), from `ds/project/fonts/`. The licence allows
  bundling them with software; the fonts are not sold on their own.
- Marks ({", ".join(MARKS)}) from `ds/project/assets/Marks/marks.json` and line glyphs from
  `ds/project/assets/Glyphs/glyphs.json` are data in `app/PixelArt.swift`.
- `people/`: People avatars ({", ".join(PEOPLE)}) from `ds/project/assets/People/`, the two sides of a call.
- `themes/`: the built-in themes. `pixel.json` is PixelKit's own look; `coffee`, `saggar` and `benidorm` are its skin
  presets from `tokens.json` (`skins`). The file format is in `docs/themes.md`.
- PixelKit (colours, marks, glyphs) is the author's own design system, MIT like Drafter. Origins and licences of
  every part: `NOTICE.md` at the repository root.
""")

marks = json.loads((pk / "ds/project/assets/Marks/marks.json").read_text())["marks"]
glyphs = json.loads((pk / "ds/project/assets/Glyphs/glyphs.json").read_text())["glyphs"]


def rects(body):
    """[(fill, [(x, y, w, h)])] from rect-only pixel paths."""
    res = []
    for fill, d in re.findall(r'<path fill="([^"]+)" d="([^"]+)"', body):
        rs = [tuple(int(v) for v in m) for m in re.findall(r"M(\d+) (\d+)h(\d+)v(\d+)", d)]
        res.append((fill, rs))
    return res


def swift_rects(body):
    parts = []
    for fill, rs in rects(body):
        col = "nil" if fill == "currentColor" else f'"{fill.lstrip("#")}"'
        parts.append(f"({col}, [" + ", ".join(f"({x},{y},{w},{h})" for x, y, w, h in rs) + "])")
    return "[" + ", ".join(parts) + "]"


lines = [f"// Generated by app/sync-pixelkit.py from PixelKit {version}. Do not hand-edit.",
         "// Marks: the 16 grid, each part a fill colour (nil = the line colour) and its cells (x, y, w, h).",
         "// Glyphs: 24 x 24 line icons (SVG bodies, 1.5 px stroke).",
         "enum PixelArt {",
         "    typealias Cells = [(String?, [(Int, Int, Int, Int)])]",
         "    static let marks: [String: Cells] = ["]
for m in MARKS:
    lines.append(f'        "{m}": {swift_rects(marks[m]["16"])},')
lines += ["    ]", "    static let glyphs: [String: String] = ["]
for g in GLYPHS:
    lines.append(f'        "{g}": {json.dumps(glyphs[g])},')
for g, body in GLYPH_GAPS.items():
    lines.append(f'        "{g}": {json.dumps(body)},   // stand-in: not in PixelKit')
lines += ["    ]", "}"]
(app / "PixelArt.swift").write_text("\n".join(lines) + "\n")
print(f"PixelKit {version}: PixelTokens.swift, PixelArt.swift, art/ ({len(FONTS)} fonts, {len(MARKS)} marks, {len(GLYPHS)} glyphs)")

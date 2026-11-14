# Themes

Drafter draws every colour, face, corner and its one shadow from a theme. A theme is a small JSON file in the same
shape as a PixelKit skin preset (`skins.<name>` in PixelKit's `tokens.json`).

## Where themes come from

- Built in, in the app's Resources (source: `app/art/themes/`, written by `app/sync-pixelkit.py`):
  - `pixel`: PixelKit's own look, the default.
  - `coffee`: plain, the system font, small soft corners.
  - `saggar`: smoke grey and carbon, one plum accent, Alegreya and Ysabeau Office if they are installed.
  - `benidorm`: white and warm sand, one coral accent, Source Sans 3 if it is installed.
- Your own: any `*.json` in `data/themes/`. It shows in Settings as `my-<file name>`.

Pick one in Settings > Look > Theme. The same row sets the mode: follow the system, light or dark. The choice is kept
in `data/look.json` and applies at once, without a restart. Settings reads `data/themes/` again each time it opens.

## The file

```json
{
  "name": "Night shift",
  "light": { "ground": "#ffffff", "raised": "#ffffff", "soft": "#f4f4f5", "ink": "#18181b", "quiet": "#52525b",
             "faint": "#6b6b74", "accent": "#2563eb", "good": "#15803d", "bad": "#b91c1c", "waiting": "#a16207",
             "mix": "#18181b" },
  "dark":  { "ground": "#161618", "raised": "#1e1e21", "soft": "#26262a", "ink": "#ececee", "quiet": "#a8a8b0",
             "faint": "#8e8e97", "accent": "#6ea8fe", "good": "#4ade80", "bad": "#f87171", "waiting": "#facc15",
             "mix": "#ffffff" },
  "fonts": { "display": "\"Fixel Display\", system-ui", "body": "\"Fixel Text\", -apple-system", "mono": "\"JetBrains Mono\", ui-monospace" },
  "numbers": "tabular",
  "corners": [0, 4, 8, 12],
  "edge": { "light": 40, "dark": 34 },
  "shadow": "0 8px 24px -6px rgb(0 0 0 / .18)"
}
```

| Key | What it is |
|---|---|
| `name` | The name in Settings. |
| `light`, `dark` | Eleven colours each, `#rrggbb`: `ground` (the window), `raised` (panels, cards, fields), `soft` (keys, the time gutter, tints), `ink` (text), `quiet` (secondary text), `faint` (placeholders), `accent` (the chosen row, focus, the caret), `good`, `bad`, `waiting` (states, the Settings meters), `mix` (lines and edges are mixed from it). |
| `fonts` | CSS-style family lists for `display` (titles), `body` (words) and `mono` (times, numbers, keys). The first family that is bundled (Fixel Text, Fixel Display, JetBrains Mono) or installed on this Mac wins. `-apple-system`, `system-ui`, `sans-serif` mean the system face; `ui-monospace`, `monospace` the system mono; `serif` means Georgia. Nothing is downloaded. `font` (one list) fills `display` and `body`. |
| `numbers` | `"tabular"`: with no `mono` list, numbers use the body face with even digits. |
| `corners` | Four radii in points: square, keys and tags, controls, floating panels. |
| `edge` | How much of `mix` a field or key edge takes, in % (default 40 light, 34 dark). |
| `shadow` | A CSS box shadow; the last layer gives the drop, the blur and how dark it is. `"none"`: flat. |
| `tokens` | Optional, exact values for single colour jobs (`pixel` uses it to keep PixelKit's own values). |

Every other colour is derived the way PixelKit derives a skin: lines are `mix` at 9 % and 18 %, edges at `edge` %,
the chosen-row tint is `accent` at 10 %, the state tints are 10-14 %. In a skin the four series colours fold into
`accent`, `quiet`, `faint` and `ink`, so colour is left for states; the pixel marks keep their own colours.

## The gates

A theme must pass PixelKit's contrast gates in both modes, or Drafter refuses it:

- text 4.5:1: `ink`, `quiet` and `faint` on `ground` and `raised`; `ink` and `quiet` on `soft` and on each state tint;
  `ground` on `ink` (the main button);
- marks and edges 3:1: `accent`, `good`, `bad`, `waiting`, `quiet`, `faint` on `ground` and `raised`; the edge on both;
  the focus ring (`accent`) on `soft`.

A refused theme is not listed in the picker. Its first reasons go to `data/app.log` (`theme: my-night refused: ...`)
and under the Theme row in Settings, one line each, with the ratio it has and the ratio it needs.
`tests/theme_rules.swift` checks the built-in files and a weak made-up theme.

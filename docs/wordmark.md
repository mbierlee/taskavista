# The wordmark

The "taskavista" logotype in the top bar is `dashboard/public/wordmark.svg`, drawn from the
"Taskavista Wordmark" canvas in the Claude Design project (see the `taskavista-designs` skill).

## The design

| | |
|---|---|
| Text | `taskavista`, all lowercase |
| Typeface | [Lexend](https://fonts.google.com/specimen/Lexend), SIL OFL |
| Weight | 600 (SemiBold) |
| Letter-spacing | −2px at 60px, i.e. −0.033em. The top bar size is 21px at −0.7px |
| Colours | `taska` in `#F2F4F6` (`--text`), `vista` in `#8FA6FF` (`--accent`) |
| Size in the top bar | 21px font size, which is 16.8px of ink height |

Lexend is used only for the wordmark. The rest of the UI is set in Figtree.

## The SVG

The letters are outlined paths, not `<text>`, so the page never loads Lexend. The viewBox is
cropped to the ink, with no side bearings or line gap around it, so its height is the height of
the letters themselves (0.8em). `tv-topbar` shows it as an `<img>` with `height: 16.8px` and
lets the width follow (about 100px).

Because it is an `<img>`, the custom properties in `app.css` do not reach inside it. The two
colours are written into the file. If `--text` or `--accent` changes, change the SVG too.

## Regenerating it

There is no script for this in the repo. It was made with Python, using `fontTools` and
`uharfbuzz` (`pip install --target <dir> fonttools uharfbuzz`). Starting from the variable
`Lexend[wght].ttf` in the google/fonts repo:

1. Pin the variable font to `wght` 600 with `fontTools.varLib.instancer`.
2. Shape `taskavista` with HarfBuzz so the font's kerning is applied, as a browser would.
3. Draw each glyph through an `SVGPathPen`, scaled to 60px. Add the advance plus −2px after
   each glyph, and flip y.
4. Put glyphs 0–4 in one `<path>` and glyphs 5–9 in another. Fill them with the two colours,
   and set the viewBox to the combined bounds.

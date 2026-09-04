# Strip alignment templates

Transparent PNGs at the exact print size, for checking custom artwork before it
reaches a printer.

| File | Shots | Logo | Photo well |
|---|---|---|---|
| `strip-3shot.png` | 3 | no | 1076 x 1030 |
| `strip-3shot-logo.png` | 3 | yes | 1076 x 990 |
| `strip-4shot.png` | 4 | no | 1076 x 765 |
| `strip-4shot-logo.png` | 4 | yes | 1076 x 735 |

All four are 1200 x 3600 px, which is exactly 2 x 6 inches at 600 dpi.

## Using one

Open your overlay artwork in any editor, drop the matching template in as a
layer on top, and look at what covers what.

- **Cyan boxes are photos.** Anything opaque over one covers a guest's face.
  Marked *PLACE HERE TO SEE IF IT'S CORRECT* so you can tell at a glance
  whether the artwork lines up with where the photos will actually land.
- **Magenta dashes are the safe margin.** The cutter is not perfectly
  registered, so anything outside them may be trimmed off.
- **Small ticks** on each well mark its centre, for registering a frame or mask
  without measuring.

Delete the template layer before exporting. The finished overlay is a
transparent PNG at 1200 x 3600 with nothing but your own artwork in it.

Pick the file matching the shot count *and* whether a logo is set: a logo takes
120 px of height from the footer, which shortens every photo.

## Regenerating

```
py make_templates.py
```

The geometry is computed from the same constants the booth uses, so the
templates cannot drift from what prints. If a strip setting changes in
`../index.html`, change it at the top of `make_templates.py` and rerun.

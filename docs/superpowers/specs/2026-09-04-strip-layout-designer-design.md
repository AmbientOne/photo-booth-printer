# Strip layout designer

Date: 2026-09-04
Status: approved, not yet implemented

## Problem

The strip renderer computes its layout. renderStrip() derives photo height from
whatever space the padding and footer leave over, and the only controls are a
handful of numbers: border style, corner radius, gap, padding, footer size.
There is no way to put text above the photos, to make the photos smaller than
the space allows, to place a logo anywhere but the footer, or to see a design
before an event.

Everything decorative therefore has to be done outside the booth as an overlay
PNG, which cannot move the photos.

## Goal

A visual editor producing a saved layout that the renderer draws literally, so
the host controls what goes where on the 2x6 strip and sees it before it goes
live.

## Non-goals

- Replacing the current renderer. It stays, unchanged, as the default and the
  fallback. A half-finished design must never be able to take the booth down.
- A general design tool. Four element types, no layers panel beyond z-order,
  no effects.
- Designing on the iPad. Dragging precisely with a finger is unpleasant; the
  editor is for a laptop.

## Design

### The layout is data

```json
{
  "version": 1,
  "canvas": { "w": 1200, "h": 3600 },
  "background": "#fdfbf5",
  "elements": [
    { "id": "a1", "type": "text",  "x": 62, "y": 90, "w": 1076, "h": 90,
      "source": "field", "field": "title", "align": "center",
      "font": "Playfair Display", "size": 52, "weight": 600,
      "italic": true, "color": "#1a1814" },
    { "id": "a2", "type": "photo", "x": 62, "y": 210, "w": 1076, "h": 700,
      "index": 0, "radius": 0 },
    { "id": "a3", "type": "shape", "x": 48, "y": 48, "w": 1104, "h": 3504,
      "fill": null, "stroke": "#c9a24b", "strokeWidth": 4, "radius": 0 },
    { "id": "a4", "type": "image", "x": 400, "y": 3300, "w": 400, "h": 120,
      "src": "logo" }
  ]
}
```

Elements draw in array order, so z-order is list order.

Four element types. photo consumes one captured image, chosen by index, drawn
to cover its box and cropped to it. text is either literal or bound to an event
field. image is the uploaded logo, the uploaded overlay, or an inline data URI.
shape is a rectangle with optional fill, stroke and corner radius, present
because borders are the natural use of it and the alternative is shipping a
border PNG per colour.

The shot count comes from the layout. The number of photo elements is the
number of shots, so there is nothing to keep in sync with a separate setting.

Bound text disappears when its field is empty, the same rule as the classic
footer. In a free-form canvas the space cannot close up, because the renderer
cannot know what should move, so the block simply does not draw and leaves its
space empty. A stack container that collapses is a later addition if it is
wanted; it is not in this design.

### Storage

The layout lives on the print server, not in browser storage, so it can be
designed on a laptop and used by the iPad.

| Route | Method | Behaviour |
|---|---|---|
| /layout | GET | The saved layout, or 404 when none is saved |
| /layout | PUT | Validate and save; 400 with a reason when invalid |
| /designer | GET | Serves photo-booth/designer.html |

Saved to DATA_DIR/layout.json, so it sits with the archive and the logs and is
covered by the same backup. Validation on save: version, canvas size, known
element types, numeric geometry, at least one photo element, and a size cap.

Writes go through a temp file and a rename, the same way prints reach the hot
folder, so a partial write cannot leave an unreadable layout behind.

### Renderer

renderLayout(imgs, layout) sits beside renderStrip(), which is untouched. It
creates the same 1200x3600 canvas and walks the element list. Shared helpers,
drawCover, roundPath, ftext and theme, are reused.

renderCurrent() chooses between them:

    CONFIG.layoutMode === "designed" and a valid layout loaded
        -> renderLayout()
    otherwise
        -> renderStrip()

The booth fetches /layout at startup. A 404, a network failure, or a layout
that fails validation falls back to classic and shows a toast. This is the
safety property the whole design rests on.

### Designer UI

photo-booth/designer.html, standalone, sharing no state with the booth page.

The canvas is drawn scaled to fit the window with the safe margin marked.
Elements are DOM nodes positioned over it, so dragging and resizing use
ordinary mouse events rather than hit-testing on a canvas. Snapping to the safe
margin, to canvas edges, and to the edges and centres of other elements.

- Toolbar: add photo, text, image or shape; undo; save
- Element list for z-order and selection
- Properties panel for the selected element: position, size, and its own
  fields (font, size, colour, alignment for text; radius for photo; stroke,
  fill and radius for shape)
- Live preview rendered by the real renderLayout() against sample images, so
  what is previewed is what prints

Sharing the renderer between the designer and the booth is the point: a preview
drawn by different code is not a preview.

### Switching

A new Strip Layout section in setup with two choices, Classic and Designed,
defaulting to Classic, and the designer URL shown as text. Setting Designed
with no saved layout is refused with an explanation rather than silently
falling back.

## Testing

The renderer is testable the way drawFooter was: extract it, run it against a
recording canvas in node, and assert.

- Elements draw in list order at their stated geometry
- Bound text with an empty field draws nothing, and nothing else moves
- Literal text always draws
- photo elements map to captured images by index
- A layout with no photo element is rejected by validation
- Malformed and oversized layouts are rejected by PUT /layout
- A missing or invalid layout falls back to classic

Plus rendering real PNGs and checking them against the alignment templates in
photo-booth/templates/.

## What does not change

/print, the hot folder path, duplicate detection, the archive, the certificate,
and the classic renderer. The print path sees a JPEG of the same dimensions
either way.

## Risks

Scope. Roughly 600 to 900 lines across three areas. The mitigation is that none
of it is load-bearing until the host switches to Designed.

Editing on a small screen. The designer assumes a laptop, and should say so
rather than degrade quietly on an iPad.

Layout drift. A layout designed against four photos still renders as four if
the host later wants three. Deriving the shot count from the layout removes the
mismatch, but changing the count means re-designing. Accepted.

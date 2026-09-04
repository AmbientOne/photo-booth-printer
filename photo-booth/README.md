# Event Photo Booth

A single-page web photo booth for events, designed to run on an iPad on a stand.
Guests take a single photo or a 4-shot strip, the app wraps it in an elegant branded
frame (event title / venue / date), and they send it to themselves via the native
share sheet (Messages, Mail, AirDrop) or save it to Photos.

## Features

- **Two modes:** Single Shot and 4-Shot Strip (classic photobooth)
- **Branded frame:** cream "polaroid" card with gold border, ◇ divider, and event caption
- **In-app setup:** host sets title / venue / date / tagline (saved in the browser)
- **Camera:** front/selfie by default with front/rear flip and an optional 3s countdown
- **Send to me:** native Web Share API → Messages / Mail / AirDrop / Save to Photos
- **Zero dependencies, zero backend** — one `index.html`

## Running

The camera and share sheet require a **secure context** (HTTPS or `localhost`).

Local:

```bash
python3 -m http.server 8000
# open http://localhost:8000
```

In production the print server hosts this page itself, at
`https://192.168.137.1:5443/booth`, so the page and the print API share one
origin. It also works on any static host, but a page served over public HTTPS
cannot POST to a plain-HTTP address on the local network.

## Tech

Vanilla HTML/CSS/JS. Photos are composited on a `<canvas>` and shared as a JPEG `File`.

# Photo Booth

An event photo booth: an iPad on a stand for guests, a Windows mini PC as the
server, and a DNP DS620A dye-sublimation printer for the prints.

The mini PC hosts **its own Wi-Fi network**, so the booth works in a venue with
no usable Wi-Fi, and its address never changes from event to event.

```
   iPad (Safari)                mini PC                      DNP DS620A
  ┌──────────────┐   Wi-Fi    ┌────────────────────┐        ┌──────────┐
  │ photo-booth  │ ─────────▶ │ :5443 HTTPS cheroot│        │          │
  │  index.html  │  POST      │ :5000 HTTP waitress│        │          │
  │              │  /print    │        │           │        │          │
  └──────────────┘            │        ▼           │        │          │
    camera, framing,          │  hot folder ───────┼──────▶ │  prints  │
    share sheet               │  + archive copy    │  HFP   │          │
                              └────────────────────┘        └──────────┘
```

The server never talks to the printer. It drops a JPEG into the folder DNP's
Hot Folder Print utility watches, and HFP does the printing — which means a
printer jam or an empty ribbon queues work rather than losing it.

## Layout

| Path | What it is |
|---|---|
| `photo-booth/index.html` | The whole guest-facing app. Vanilla JS, no build, no backend. |
| `print-server/app.py` | Flask app: `/print`, `/status`, `/cert`, `/booth`. |
| `print-server/make_cert.py` | Generates the local root CA and server certificate. |
| `scripts/` | Windows setup: hotspot, firewall, startup tasks, health check. |
| `RUNBOOK.md` | Operator instructions and one-time machine setup. |
| `SECURITY-CLEANUP.md` | How to undo everything on the PC and the iPad. |

Photos, logs and the print token live in `C:\PhotoBooth`, outside the checkout.

## Design notes

**Two servers, no development server.** Waitress handles `:5000` and cheroot
handles `:5443`. Waitress has no TLS support, and iOS only grants camera access
on a secure context, so HTTPS is not optional — the booth's core feature
depends on it. Cheroot is a production WSGI server with a built-in SSL adapter,
which beat hand-rolling a TLS proxy in front of waitress.

**A throwaway certificate authority.** `make_cert.py` generates a root CA in
memory, signs one server certificate with it, and never writes the CA key to
disk. The iPad installs that root with full trust; if its private key survived
anywhere, whoever held it could impersonate any website to that device.

**Duplicate prints are the expensive failure.** Media costs real money, so
every print carries a `job_id`. The archive directory is the durable ledger —
the set of already-printed jobs is rebuilt from disk at startup, so a restart
mid-event cannot let the iPad reprint what it already sent.

**Print size is a whitelist, never a path.** The client picks `4x6` or `2x6`;
the server maps that to a folder. `job_id` is likewise constrained to
`[A-Za-z0-9_-]{1,64}` before it is ever used as a filename.

**Uploads are checked, not trusted.** Extension, JPEG magic bytes, and a 25 MB
cap, before anything touches the filesystem.

## Running it

See **[RUNBOOK.md](RUNBOOK.md)**. Short version:

```powershell
py -m pip install -r print-server/requirements.txt
py print-server/make_cert.py
.\scripts\install.ps1 -Ssid "PhotoBooth" -Passphrase "..." -EnableAutoLogon
```

For development, without a printer attached:

```powershell
$env:PHOTOBOOTH_HOT_FOLDER = "C:\temp\fakeprinter"   # dry run
py print-server/app.py
```

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `PHOTOBOOTH_TOKEN` | generated, saved to disk | Shared secret for `POST /print` |
| `PHOTOBOOTH_DATA_DIR` | `C:\PhotoBooth` | Archive, logs, token |
| `PHOTOBOOTH_HOT_FOLDER` | unset | Dry run: send every size here |
| `PHOTOBOOTH_HOT_FOLDER_ROOT` | `C:\DNP\HotFolderPrint\Prints` | HFP install location |
| `PHOTOBOOTH_ADVERTISED_IP` | auto-detected | Address used in logged URLs and the cert check |
| `PHOTOBOOTH_BIND` | `0.0.0.0` | Listen address |

## Security model

This is a **local-network appliance**, not an internet service. It assumes the
only people who can reach it are the ones standing in the room.

- `POST /print` requires a shared token, compared in constant time. Everything
  else — the booth page, `/status`, `/cert` — is deliberately open, since a
  device needs them before it has been provisioned.
- The firewall rule installed by `scripts/install.ps1` accepts connections from
  `192.168.137.0/24` only, so the ports are not exposed on any other network
  the machine later joins.
- **There is no rate limiting.** A client holding the token can print in a loop.
  On a private network with the operator present that is an acceptable trade;
  on any wider network it would not be.
- `archive/` holds a copy of every printed photo, guests' faces included.
  Decide a retention policy before an event, not after. See
  [SECURITY-CLEANUP.md](SECURITY-CLEANUP.md).

## Licence

MIT — see [LICENSE](LICENSE).

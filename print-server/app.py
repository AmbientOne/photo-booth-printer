r"""
Photo Booth print server.

Receives finished JPEGs from the iPad photo booth over the local network,
archives a master copy, and drops a print copy into the DNP Hot Folder Print
watched folder for the DS620A. Hot Folder Print does the actual printing --
this server never talks to the printer directly.

The mini PC runs its own Wi-Fi access point (Windows Mobile Hotspot), so the
booth does not depend on venue Wi-Fi and the server's address is the fixed ICS
gateway 192.168.137.1 rather than whatever DHCP hands out that evening.

Layout:
    code   ->  <repo>\print-server\app.py       (this file, version controlled)
    data   ->  C:\PhotoBooth\{archive,logs}     (event output, not in git)
    booth  ->  <repo>\photo-booth\index.html    (served at /booth)

Run:  py app.py          (or let the scheduled task start it -- see scripts\)
"""

import hmac
import logging
import os
import re
import secrets
import shutil
import socket
import threading
import uuid
from datetime import datetime
from logging.handlers import RotatingFileHandler
from pathlib import Path

from flask import Flask, jsonify, request, send_from_directory

# ---------------------------------------------------------------- config ----

CODE_DIR = Path(__file__).resolve().parent

# Runtime data lives outside the repo -- an event produces thousands of JPEGs.
DATA_DIR = Path(os.environ.get("PHOTOBOOTH_DATA_DIR", r"C:\PhotoBooth"))
ARCHIVE_DIR = DATA_DIR / "archive"
LOG_DIR = DATA_DIR / "logs"

# The guest-facing booth page, served straight from the repo checkout so there
# is no copy to keep in sync.
BOOTH_DIR = Path(os.environ.get("PHOTOBOOTH_BOOTH_DIR", CODE_DIR.parent / "photo-booth"))

# DNP Hot Folder Print watched folders. Verified on this printer 2026-08-28:
#
#   4x6    -> s4x6     one full 4x6 postcard.
#   2x6    -> s2x6     HFP duplicates the strip and cuts: TWO identical 2x6
#                      strips per sheet. Feed it a single 1:3 strip image.
#   6x2_2  -> s6x2_2   cuts, but crops to a landscape 1836x1224 frame, so it
#                      expects a pre-built two-up sheet. Not used by the booth.
#   3.5x5  -> s3P5x5   untested.
#
# Sizes are a fixed whitelist -- the client picks a name, never a path.
HOT_FOLDER_ROOT = Path(
    os.environ.get("PHOTOBOOTH_HOT_FOLDER_ROOT", r"C:\DNP\HotFolderPrint\Prints")
)
PRINTER_DIR = "DS620"
PRINT_SIZES = {
    "4x6": "s4x6",
    "2x6": "s2x6",
    "6x2_2": "s6x2_2",
    "3.5x5": "s3P5x5",
}
DEFAULT_SIZE = "4x6"

# Dry-run escape hatch: when set, every size lands here instead of the printer.
_DRY_RUN_FOLDER = os.environ.get("PHOTOBOOTH_HOT_FOLDER")


def hot_folder_for(size):
    """Watched folder for a whitelisted print size."""
    if _DRY_RUN_FOLDER:
        return Path(_DRY_RUN_FOLDER)
    return HOT_FOLDER_ROOT / PRINT_SIZES[size] / PRINTER_DIR

HOST = os.environ.get("PHOTOBOOTH_BIND", "0.0.0.0")
PORT = int(os.environ.get("PHOTOBOOTH_PORT", "5000"))

# Windows Mobile Hotspot (Internet Connection Sharing) always assigns the host
# machine 192.168.137.1. Because the mini PC *is* the access point, that address
# is stable across venues -- which is what lets the certificate be pinned once
# instead of regenerated whenever the network changes.
AP_HOST_IP = "192.168.137.1"

# iOS Safari only grants camera access on a secure context, so the iPad has to
# load the booth over HTTPS. Certs live next to the code; if they are missing
# the server just runs HTTP and says so.
HTTPS_PORT = int(os.environ.get("PHOTOBOOTH_HTTPS_PORT", "5443"))
CERT_FILE = CODE_DIR / "certs" / "cert.pem"   # leaf + issuer chain
KEY_FILE = CODE_DIR / "certs" / "key.pem"     # leaf private key
CA_FILE = CODE_DIR / "certs" / "ca.pem"       # the root the iPad installs

# A finished 4x6 booth JPEG is normally 1-4 MB. 25 MB is generous but bounded.
MAX_UPLOAD_BYTES = 25 * 1024 * 1024

# job_id must be safe to use as a filename -- no paths, no traversal.
JOB_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
ALLOWED_EXTENSIONS = {".jpg", ".jpeg"}
JPEG_MAGIC = b"\xff\xd8\xff"

for _d in (ARCHIVE_DIR, LOG_DIR):
    _d.mkdir(parents=True, exist_ok=True)

# --------------------------------------------------------------- address ----


def _local_addresses():
    """Every IPv4 address this machine currently holds, loopback excluded."""
    addrs = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addrs.add(info[4][0])
    except OSError:
        pass
    # The hostname lookup misses some adapters; ask the routing table too.
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("8.8.8.8", 80))          # no packet is actually sent
        addrs.add(probe.getsockname()[0])
    except OSError:
        pass
    finally:
        probe.close()
    addrs.discard("127.0.0.1")
    return sorted(addrs)


def advertised_ip():
    """The address to print in URLs and check the certificate against.

    Prefers the hotspot gateway: holding 192.168.137.1 means this machine is
    the access point, and every iPad on it reaches the booth there.
    """
    env = os.environ.get("PHOTOBOOTH_ADVERTISED_IP")
    if env:
        return env.strip()
    addrs = _local_addresses()
    if AP_HOST_IP in addrs:
        return AP_HOST_IP
    return addrs[0] if addrs else "127.0.0.1"


def cert_covers(ip):
    """Whether the leaf certificate lists `ip` in its SAN.

    Returns None when it cannot be determined (cryptography not installed), so
    callers can tell "mismatch" apart from "unknown".
    """
    if not CERT_FILE.is_file():
        return False
    try:
        import ipaddress

        from cryptography import x509
    except ImportError:
        return None
    try:
        cert = x509.load_pem_x509_certificate(CERT_FILE.read_bytes())
        san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        return ipaddress.ip_address(ip) in set(san.get_values_for_type(x509.IPAddress))
    except Exception:
        return None


# --------------------------------------------------------------- logging ----

logger = logging.getLogger("printserver")
logger.setLevel(logging.INFO)
_fmt = logging.Formatter("%(asctime)s %(levelname)-8s %(message)s")

_file_handler = RotatingFileHandler(
    LOG_DIR / "print_server.log",
    maxBytes=2 * 1024 * 1024,
    backupCount=10,
    encoding="utf-8",
)
_file_handler.setFormatter(_fmt)
logger.addHandler(_file_handler)

_console = logging.StreamHandler()
_console.setFormatter(_fmt)
logger.addHandler(_console)

# ------------------------------------------------------- duplicate guard ----

_lock = threading.Lock()
_printed_jobs = set()   # jobs already dropped into the hot folder
_in_flight = set()      # jobs being handled right now


def _seed_printed_jobs():
    """Archive is the durable record: a job we archived was already printed.

    Seeding from disk means a mid-event restart cannot let the iPad re-print
    jobs it already sent.
    """
    for f in ARCHIVE_DIR.glob("*.jpg"):
        _printed_jobs.add(f.stem)
    logger.info("Loaded %d previously printed job ids from archive", len(_printed_jobs))


_seed_printed_jobs()

# ------------------------------------------------------------------ auth ----
# Anyone on the Wi-Fi can reach this port, so by default /print requires a
# shared secret. The booth picks it up from ?k=<token> once and remembers it; a
# stranger on the network can load the page but cannot spend your media.
#
# Set PHOTOBOOTH_AUTH=off to drop that. Reasonable only when the network itself
# is the perimeter -- a hidden SSID, a long passphrase, nobody but the booth on
# it -- because then the token is a third lock behind two better ones, and the
# ?k= URL is one more thing to get wrong when provisioning a device. On any
# shared or venue network, leave it on: it is the only thing standing between a
# stranger and a roll of media.

TOKEN_FILE = DATA_DIR / "token.txt"

_auth_setting = os.environ.get("PHOTOBOOTH_AUTH", "").strip().lower()
AUTH_ENABLED = _auth_setting not in ("off", "0", "no", "none", "false")


def _load_token():
    env = os.environ.get("PHOTOBOOTH_TOKEN")
    if env:
        return env.strip()
    try:
        if TOKEN_FILE.is_file():
            existing = TOKEN_FILE.read_text(encoding="utf-8").strip()
            if existing:
                return existing
    except OSError:
        pass
    fresh = secrets.token_hex(8)
    try:
        TOKEN_FILE.write_text(fresh, encoding="utf-8")
    except OSError as exc:
        logger.warning("Could not save token to %s: %s", TOKEN_FILE, exc)
    return fresh


TOKEN = _load_token() if AUTH_ENABLED else ""


def _token_ok():
    """Constant-time check of the header, with a form field as fallback."""
    if not AUTH_ENABLED:
        return True
    supplied = request.headers.get("X-Booth-Token") or request.form.get("token") or ""
    return hmac.compare_digest(str(supplied), str(TOKEN))


def _sweep_stale_temp():
    """Remove half-written .jpg.tmp files left by a crash mid-copy.

    Only our own temp files are touched. Finished .jpg files are left alone --
    Hot Folder Print deletes those itself once printed, so anything still
    sitting there is a job that has NOT printed yet (printer busy, out of
    media, cover open). Purging those would silently cancel a guest's print.
    """
    removed = 0
    for name in PRINT_SIZES:
        folder = hot_folder_for(name)
        if not folder.is_dir():
            continue
        for tmp in folder.glob("*.jpg.tmp"):
            try:
                tmp.unlink()
                removed += 1
                logger.warning("Removed stale temp file %s", tmp)
            except OSError as exc:
                logger.warning("Could not remove %s: %s", tmp, exc)
    if removed:
        logger.info("Swept %d stale temp file(s)", removed)


_sweep_stale_temp()

# ------------------------------------------------------------------- app ----

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_BYTES

STARTED_AT = datetime.now()


def _client_ip():
    return request.remote_addr or "?"


@app.get("/status")
def status():
    """Health check the iPad can poll before enabling the Print button."""
    sizes = {}
    for name in PRINT_SIZES:
        folder = hot_folder_for(name)
        sizes[name] = {
            "folder": str(folder),
            "ready": folder.is_dir() and os.access(folder, os.W_OK),
        }
    default_folder = hot_folder_for(DEFAULT_SIZE)
    hot_folder_ok = default_folder.is_dir() and os.access(default_folder, os.W_OK)
    with _lock:
        printed = len(_printed_jobs)
    body = jsonify(
        status="ready" if hot_folder_ok else "degraded",
        printer="DNP DS620A",
        sizes=sizes,
        default_size=DEFAULT_SIZE,
        dry_run=bool(_DRY_RUN_FOLDER),
        auth_required=AUTH_ENABLED,
        hot_folder=str(default_folder),
        hot_folder_ready=hot_folder_ok,
        queued_in_hot_folder=len(list(default_folder.glob("*.jpg"))) if hot_folder_ok else None,
        prints_this_install=printed,
        max_upload_mb=round(MAX_UPLOAD_BYTES / 1024 / 1024, 1),
        data_dir=str(DATA_DIR),
        advertised_ip=ADVERTISED_IP,
        access_point=ADVERTISED_IP == AP_HOST_IP,
        https_ready=HTTPS_READY,
        booth_page=str(BOOTH_DIR / "index.html") if (BOOTH_DIR / "index.html").is_file() else None,
        server_time=datetime.now().isoformat(timespec="seconds"),
        uptime_seconds=int((datetime.now() - STARTED_AT).total_seconds()),
    )
    return body, (200 if hot_folder_ok else 503)


@app.post("/print")
def print_photo():
    if not _token_ok():
        logger.warning("UNAUTHORIZED print attempt from %s", _client_ip())
        return jsonify(
            status="error",
            error="Missing or invalid token. Open the booth with ?k=<token>.",
        ), 401

    job_id = (request.form.get("job_id") or "").strip()
    size = (request.form.get("size") or DEFAULT_SIZE).strip()
    file = request.files.get("image")

    logger.info(
        "PRINT request from %s job_id=%s size=%s", _client_ip(), job_id or "(none)", size
    )

    if size not in PRINT_SIZES:
        logger.warning("REJECTED from %s: unknown size %r", _client_ip(), size)
        return jsonify(
            status="error",
            error="Unknown size. Valid: " + ", ".join(sorted(PRINT_SIZES)),
        ), 400

    if file is None or not file.filename:
        logger.warning("REJECTED from %s: no image field", _client_ip())
        return jsonify(status="error", error="Missing 'image' file field"), 400

    if job_id:
        if not JOB_ID_RE.match(job_id):
            logger.warning("REJECTED from %s: bad job_id %r", _client_ip(), job_id)
            return jsonify(
                status="error",
                error="job_id must be 1-64 chars of letters, numbers, dash or underscore",
            ), 400
    else:
        job_id = uuid.uuid4().hex
        logger.info("Generated job_id=%s", job_id)

    ext = Path(file.filename).suffix.lower()
    if ext not in ALLOWED_EXTENSIONS:
        logger.warning("REJECTED job=%s: extension %r not allowed", job_id, ext)
        return jsonify(
            status="error", error="Only .jpg / .jpeg files are accepted", job_id=job_id
        ), 415

    head = file.stream.read(3)
    file.stream.seek(0)
    if head != JPEG_MAGIC:
        logger.warning("REJECTED job=%s: not a JPEG (magic=%s)", job_id, head.hex())
        return jsonify(
            status="error", error="File content is not a JPEG", job_id=job_id
        ), 415

    # Claim the job id before doing any work.
    with _lock:
        if job_id in _printed_jobs:
            logger.warning("DUPLICATE job=%s from %s -- not printing again", job_id, _client_ip())
            return jsonify(
                status="duplicate",
                job_id=job_id,
                message="This job_id was already printed",
            ), 409
        if job_id in _in_flight:
            logger.warning("DUPLICATE job=%s from %s -- already in progress", job_id, _client_ip())
            return jsonify(
                status="duplicate",
                job_id=job_id,
                message="This job_id is already being printed",
            ), 409
        _in_flight.add(job_id)

    hot_folder = hot_folder_for(size)
    archive_path = ARCHIVE_DIR / (job_id + ".jpg")
    hot_path = hot_folder / (job_id + ".jpg")
    temp_path = hot_folder / (job_id + ".jpg.tmp")

    try:
        if not hot_folder.is_dir():
            raise FileNotFoundError("Hot folder missing: " + str(hot_folder))

        # 1. Master copy first -- if anything downstream fails we still have the photo.
        file.save(archive_path)
        nbytes = archive_path.stat().st_size
        if nbytes == 0:
            raise ValueError("Uploaded file was empty")

        # 2. Write into the hot folder as .tmp, then rename. Hot Folder Print
        #    only picks up .jpg, so it never sees a half-written file.
        shutil.copyfile(archive_path, temp_path)
        os.replace(temp_path, hot_path)

        with _lock:
            _printed_jobs.add(job_id)

        logger.info(
            "PRINTED job=%s size=%s bytes=%d -> %s", job_id, size, nbytes, hot_path
        )
        return jsonify(
            status="printed",
            job_id=job_id,
            size=size,
            bytes=nbytes,
            archive=str(archive_path),
            hot_folder_file=str(hot_path),
        ), 200

    except Exception as exc:  # booth must fail loudly in the log, softly to the iPad
        logger.exception("FAILED job=%s: %s", job_id, exc)
        try:
            if temp_path.exists():
                temp_path.unlink()
        except OSError:
            pass
        # job_id is left unclaimed so the iPad can safely retry the same id.
        return jsonify(status="error", job_id=job_id, error=str(exc)), 500

    finally:
        with _lock:
            _in_flight.discard(job_id)


@app.get("/cert")
def download_cert():
    """Hand the root CA to the iPad so it can be trusted once.

    This is ca.pem, not the server leaf: the CA's private key was discarded at
    generation time (see make_cert.py), so trusting this root does not hand
    anyone the ability to mint certificates for other sites.

    Served over plain HTTP too -- the device cannot make a trusted HTTPS
    connection until it has this file.
    """
    source = CA_FILE if CA_FILE.is_file() else CERT_FILE
    if not source.is_file():
        return jsonify(
            status="error",
            error="No certificate generated. Run: py make_cert.py",
        ), 404
    return send_from_directory(
        source.parent, source.name,
        as_attachment=True, mimetype="application/x-x509-ca-cert",
        download_name="photobooth.crt",
    )


@app.get("/")
@app.get("/booth")
@app.get("/booth/<path:filename>")
def booth(filename="index.html"):
    """Serve the booth page itself from this machine.

    An HTTPS-hosted booth page cannot fetch() a plain-http LAN address, so
    loading the booth from http://<mini-pc-ip>:5000/booth keeps the page and
    the print API on one origin.
    """
    target = BOOTH_DIR / filename
    if not target.is_file():
        return jsonify(status="ready", hint="POST a JPEG to /print, or GET /status"), 200
    return send_from_directory(BOOTH_DIR, filename)


@app.errorhandler(413)
def too_large(_e):
    logger.warning("REJECTED from %s: upload exceeded %d bytes", _client_ip(), MAX_UPLOAD_BYTES)
    return jsonify(
        status="error",
        error="Image too large (max {} MB)".format(MAX_UPLOAD_BYTES // 1024 // 1024),
    ), 413


@app.errorhandler(404)
def not_found(_e):
    return jsonify(status="error", error="Not found"), 404


@app.errorhandler(500)
def server_error(_e):
    return jsonify(status="error", error="Internal server error"), 500


# --------------------------------------------------------------- serving ----
# Two listeners, no Flask development server anywhere:
#
#   :5000  HTTP  via waitress -- serves /cert and the booth page to a device
#                that has not trusted the root yet.
#   :5443  HTTPS via cheroot  -- waitress has no TLS support, and cheroot is a
#                production WSGI server with a built-in SSL adapter, so this
#                avoids hand-rolling a TLS proxy in front of waitress.
#
# The HTTPS listener is what the iPad actually uses: iOS only grants camera
# access on a secure context.

ADVERTISED_IP = advertised_ip()
HTTPS_READY = CERT_FILE.is_file() and KEY_FILE.is_file()


def _start_https():
    """Run cheroot's TLS listener on a daemon thread. Returns True if started."""
    if not HTTPS_READY:
        logger.error(
            "No certificate at %s -- HTTPS disabled and the iPad camera will "
            "NOT work. Generate one with: py make_cert.py", CERT_FILE
        )
        return False

    covered = cert_covers(ADVERTISED_IP)
    if covered is False:
        logger.error(
            "Certificate does not cover %s. HTTPS will fail with a name "
            "mismatch. Regenerate with: py make_cert.py %s",
            ADVERTISED_IP, ADVERTISED_IP,
        )
    elif covered is None:
        logger.warning("Could not verify the certificate SAN (cryptography not installed)")

    try:
        from cheroot.ssl.builtin import BuiltinSSLAdapter
        from cheroot.wsgi import Server as CherootServer
    except ImportError:
        logger.error(
            "cheroot is not installed -- HTTPS disabled and the iPad camera "
            "will NOT work. Run: py -m pip install -r requirements.txt"
        )
        return False

    server = CherootServer(
        (HOST, HTTPS_PORT), app, numthreads=8, request_queue_size=32
    )
    server.ssl_adapter = BuiltinSSLAdapter(str(CERT_FILE), str(KEY_FILE))

    def _run():
        try:
            server.start()
        except Exception as exc:   # never take the HTTP listener down with it
            logger.exception("HTTPS listener failed: %s", exc)

    threading.Thread(target=_run, daemon=True, name="https").start()
    return True


if __name__ == "__main__":
    logger.info("=" * 60)
    logger.info("Photo Booth print server starting")
    logger.info("Code:       %s", CODE_DIR)
    logger.info("Data:       %s", DATA_DIR)
    logger.info("Booth page: %s", BOOTH_DIR)
    logger.info("Bind:       %s (http %d, https %d)", HOST, PORT, HTTPS_PORT)

    if ADVERTISED_IP == AP_HOST_IP:
        logger.info("Address:    %s -- this machine is the access point", ADVERTISED_IP)
    else:
        logger.warning(
            "Address:    %s -- NOT the hotspot gateway (%s). The mobile hotspot "
            r"is probably off; run scripts\hotspot.ps1",
            ADVERTISED_IP, AP_HOST_IP,
        )

    if _DRY_RUN_FOLDER:
        logger.warning("DRY RUN -- all sizes land in %s", _DRY_RUN_FOLDER)
    for _name in PRINT_SIZES:
        _f = hot_folder_for(_name)
        logger.info("Size %-6s -> %s (exists=%s)", _name, _f, _f.is_dir())

    query = "?k=" + TOKEN if AUTH_ENABLED else ""
    if _start_https():
        logger.info("HTTPS  on port %d (cheroot, cert %s)", HTTPS_PORT, CERT_FILE)
        logger.info("Booth URL:  https://%s:%d/booth%s", ADVERTISED_IP, HTTPS_PORT, query)
    else:
        logger.warning("Booth URL:  http://%s:%d/booth%s  (no camera without HTTPS)",
                       ADVERTISED_IP, PORT, query)
    logger.info("Trust cert: http://%s:%d/cert", ADVERTISED_IP, PORT)
    if AUTH_ENABLED:
        logger.info("Token file: %s", TOKEN_FILE)
    else:
        logger.warning("PRINT AUTH DISABLED -- anyone who can reach this machine "
                       "can print. The Wi-Fi passphrase is now the only thing "
                       "protecting your media.")
    logger.info("=" * 60)

    from waitress import serve

    logger.info("HTTP   on port %d (waitress)", PORT)
    serve(app, host=HOST, port=PORT, threads=8, channel_timeout=120)

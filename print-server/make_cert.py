r"""
Generate the TLS material the booth needs for a secure context on iOS.

Two-tier on purpose:

    ca.pem      short-lived root. This is the file the iPad installs and
                trusts. Its PRIVATE KEY IS NEVER WRITTEN TO DISK -- it exists
                only inside this process, long enough to sign the leaf below.
    cert.pem    server leaf (+ the CA appended, so clients get the full chain)
    key.pem     the leaf's private key. Compromising it lets someone
                impersonate THIS server, not issue certs for the whole web.

That distinction matters: a single self-signed CA:TRUE cert whose key sits in
the same folder means anyone holding that file can mint a valid certificate for
any domain on every device that trusted it.

iOS 13+ rejects a server certificate unless it has a SAN, an EKU of
serverAuth, RSA >= 2048 (or P-256), SHA-256, and a lifetime <= 825 days. All
enforced below.

Run:  py make_cert.py            # SANs default to the hotspot gateway
      py make_cert.py 10.0.0.5   # extra addresses, repeatable
"""

import datetime
import ipaddress
import sys
from pathlib import Path

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
except ImportError:
    sys.exit("Missing dependency. Run:  py -m pip install -r requirements.txt")

CERT_DIR = Path(__file__).resolve().parent / "certs"

# Windows Mobile Hotspot (ICS) always gives the host machine this address, so
# when the mini PC is its own access point the cert never needs regenerating.
AP_HOST_IP = "192.168.137.1"

LEAF_DAYS = 820          # under the 825-day iOS ceiling
CA_DAYS = 825
KEY_BITS = 2048


def _write(path, data, secret=False):
    path.write_bytes(data)
    if secret:
        # Best effort: on Windows this is advisory, the real control is NTFS.
        try:
            path.chmod(0o600)
        except OSError:
            pass
    print("  wrote {} ({} bytes)".format(path.name, len(data)))


def build(extra_hosts):
    CERT_DIR.mkdir(parents=True, exist_ok=True)

    ips = {AP_HOST_IP, "127.0.0.1"}
    dns = {"localhost", "photobooth.local"}
    for host in extra_hosts:
        try:
            ipaddress.ip_address(host)
            ips.add(host)
        except ValueError:
            dns.add(host)

    sans = [x509.IPAddress(ipaddress.ip_address(i)) for i in sorted(ips)]
    sans += [x509.DNSName(d) for d in sorted(dns)]

    now = datetime.datetime.now(datetime.timezone.utc)
    # Backdate slightly so a device with a lagging clock still accepts it.
    start = now - datetime.timedelta(hours=1)

    # ---- root CA. Key stays in memory and is discarded when we exit. ----
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=KEY_BITS)
    ca_name = x509.Name([
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "PhotoBooth"),
        x509.NameAttribute(NameOID.COMMON_NAME, "PhotoBooth Local Root"),
    ])
    ca = (
        x509.CertificateBuilder()
        .subject_name(ca_name)
        .issuer_name(ca_name)
        .public_key(ca_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(start)
        .not_valid_after(now + datetime.timedelta(days=CA_DAYS))
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True, key_cert_sign=True, crl_sign=True,
                content_commitment=False, key_encipherment=False,
                data_encipherment=False, key_agreement=False,
                encipher_only=False, decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(ca_key.public_key()), critical=False)
        .sign(ca_key, hashes.SHA256())
    )

    # ---- server leaf ----
    leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=KEY_BITS)
    leaf = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, "PhotoBooth"),
            x509.NameAttribute(NameOID.COMMON_NAME, "PhotoBooth Print Server"),
        ]))
        .issuer_name(ca_name)
        .public_key(leaf_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(start)
        .not_valid_after(now + datetime.timedelta(days=LEAF_DAYS))
        .add_extension(x509.SubjectAlternativeName(sans), critical=False)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True, key_encipherment=True,
                content_commitment=False, data_encipherment=False,
                key_agreement=False, key_cert_sign=False, crl_sign=False,
                encipher_only=False, decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False
        )
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(leaf_key.public_key()), critical=False)
        .add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()), critical=False
        )
        .sign(ca_key, hashes.SHA256())
    )

    ca_pem = ca.public_bytes(serialization.Encoding.PEM)
    leaf_pem = leaf.public_bytes(serialization.Encoding.PEM)

    print("Writing to {}".format(CERT_DIR))
    _write(CERT_DIR / "ca.pem", ca_pem)
    # Leaf first, then issuer -- the chain order TLS clients expect.
    _write(CERT_DIR / "cert.pem", leaf_pem + ca_pem)
    _write(
        CERT_DIR / "key.pem",
        leaf_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        ),
        secret=True,
    )

    print("\nValid for:")
    for i in sorted(ips):
        print("  IP   {}".format(i))
    for d in sorted(dns):
        print("  DNS  {}".format(d))
    print("\nLeaf expires {}".format(leaf.not_valid_after_utc.date()))
    print("The CA private key was never saved. Regenerate to change the SAN list.")
    print("\nInstall ca.pem on the iPad via  http://{}:5000/cert".format(AP_HOST_IP))


if __name__ == "__main__":
    build(sys.argv[1:])

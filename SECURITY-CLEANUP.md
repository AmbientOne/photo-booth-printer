# Security cleanup

Everything this project changes on the mini PC and the iPad, and how to undo
it. Most of the machine-side work is automated; the iPad is manual.

Commands marked **(admin)** need an elevated PowerShell.

---

## The quick version

**(admin)** From the repo:

```powershell
.\scripts\uninstall.ps1
```

That reverses every machine change: the two scheduled tasks, the firewall rule,
the hotspot idle-timeout override, automatic logon and its stored password, and
anything still running.

Then do the two things a script should not decide for you: [remove the
certificate from the iPad](#1-ipad--remove-the-trusted-root) and [decide what
happens to the photos](#3-guest-photos).

---

## 1. iPad — remove the trusted root

**Do this first.** The iPad trusts `PhotoBooth Local Root` as a **root
certificate authority** with full trust. The current design deliberately throws
away that CA's private key at generation time, so there is no key left to
abuse — but the trust entry should not outlive the booth, and an older
certificate generated before that change *does* have its key sitting in
`print-server\certs\key.pem`.

- Settings → General → VPN & Device Management → **PhotoBooth** → **Remove
  Profile**

Removing the profile also drops it out of Certificate Trust Settings; there is
no second toggle to undo.

Then clear the camera permission and stored site data:

- Settings → Apps → Safari → Advanced → Website Data → remove the booth's
  address (`192.168.137.1`)

And forget the booth Wi-Fi network if the iPad is going back to general use.

---

## 2. Windows — what the installer changed

`scripts\uninstall.ps1` handles all of these. They are listed so you can verify
rather than trust.

| Change | Made by | Check it is gone |
|---|---|---|
| Scheduled tasks `PhotoBooth Hotspot`, `PhotoBooth Print Server` | `install.ps1` | `Get-ScheduledTask -TaskName "PhotoBooth*"` |
| Firewall rule for TCP 5000/5443 | `install.ps1` | `Get-NetFirewallRule -DisplayName "PhotoBooth*"` |
| `PeerlessTimeoutEnabled = 0` (hotspot never idles out) | `install.ps1` | `Get-ItemProperty 'HKLM:\System\CurrentControlSet\Services\icssvc\Settings'` |
| Automatic logon + password in the registry | `install.ps1 -EnableAutoLogon` | `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'` |

### Rules Windows may have added on its own

The "Allow access" popup that appears the first time Python binds a port
creates rules permitting **any** Python script to accept inbound connections
from **any** address on that network profile — far wider than this project
needs. Both `install.ps1` and `uninstall.ps1` delete them:

```powershell
Get-NetFirewallRule -DisplayName "python.exe" -EA SilentlyContinue | Remove-NetFirewallRule
```

Should return nothing afterwards.

### Network profiles

Setting a network to **Private** makes Network Discovery and File & Printer
Sharing reachable by everyone else on it, and Windows remembers the choice per
network — so rejoining that SSID silently re-trusts it. Check what is currently
trusted:

```powershell
Get-NetConnectionProfile | Select-Object Name, NetworkCategory
```

Any *guest* or *public* network listed as `Private` should be corrected while
connected to it:

```powershell
Set-NetConnectionProfile -InterfaceAlias "Wi-Fi" -NetworkCategory Public
```

Hosting the booth's own hotspot avoids this entirely, which is part of why the
mini PC runs its own access point rather than joining the venue's.

---

## 3. Guest photos

`C:\PhotoBooth\archive\` holds a master JPEG of **every photo printed** —
faces, captured without an explicit retention notice. It is also the
duplicate-print ledger, so clearing it resets duplicate protection. Do it
between events, not during one.

```powershell
Get-ChildItem C:\PhotoBooth\archive\*.jpg | Remove-Item
```

Decide a retention policy before the next event rather than after it.

---

## 4. The server key

`print-server\certs\key.pem` is the private key for the server certificate.
Losing it lets someone impersonate *this server* to a provisioned iPad — not
issue certificates for other sites, which is the point of the split in
`make_cert.py`. It is git-ignored and should stay off shared drives, chat and
email.

Done with the booth? Delete `certs\` **and** remove the iPad profile (item 1).
Doing only one leaves the risk in place.

---

## Known limitations

Not bugs to fix before an event, but be aware of them:

- **No authentication and no rate limiting.** Anyone who can reach the machine
  can POST prints in a loop. Each upload is capped at 25 MB but the count is
  not, so `archive\` can fill the disk. Acceptable only because the network is
  private, hidden, and the operator is present. The Wi-Fi passphrase is the
  entire security model -- treat it accordingly.
- **Port 5000 is unencrypted** and serves `/booth` and `/cert`. It has to stay
  open so a new device can fetch the certificate. Once every device is
  provisioned it can be closed at the firewall, leaving only 5443.
- **Automatic logon stores a password in clear text.** Unavoidable if an
  unattended machine must recover from a power cut on its own. Use an account
  dedicated to the booth, and do not reuse the password.

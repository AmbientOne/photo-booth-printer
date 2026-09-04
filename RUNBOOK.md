# Booth runbook

Two audiences:

- **[Running an event](#running-an-event)** — for whoever is on site. One page,
  no technical knowledge assumed. The only repair anyone needs is *restart the
  computer*.
- **[Setting up a new machine](#setting-up-a-new-machine)** — done once, by
  someone comfortable with PowerShell.

---

## Running an event

### Starting up

1. Plug in the mini PC and the DNP printer. Turn the printer on **first** so it
   is ready before the software looks for it.
2. Power on the mini PC. Leave it alone for about a minute — it logs itself in,
   creates its Wi-Fi network, and starts the booth.
3. On the iPad, check Wi-Fi is connected to the booth network (the name chosen
   at setup, e.g. `PhotoBooth`). It should reconnect on its own.
4. Open the booth from the iPad's home screen icon. Take a test photo and print
   it before the first guest arrives.

That is the whole start-up. There is nothing to click on the mini PC.

### If something goes wrong

**Restart the mini PC.** Hold the power button until it switches off, wait five
seconds, turn it back on, wait a minute. Everything rebuilds itself: the Wi-Fi
network, the print server, the connection to the printer.

That fixes nearly everything, because nothing about the setup is remembered in
a way a restart could lose.

If it is still wrong after one restart:

| What you see | What it means | What to do |
|---|---|---|
| iPad can't find the booth Wi-Fi | The mini PC isn't up yet | Wait a full minute after powering on, then look again |
| Booth page won't load | Server still starting | Wait 30 seconds and reload the page |
| "Can't reach the printer" | Printer off, or out of paper/ribbon | Check the printer, then restart the mini PC |
| Photo taken, nothing prints | Printer jam or empty | Clear it — queued photos print once it's fixed |
| Camera doesn't turn on | iPad lost the security certificate | Needs the setup steps below — call your technical contact |

**Nothing is lost when you restart.** Every printed photo is already saved on
the mini PC, and a photo that was mid-print reprints when the printer recovers.

### Shutting down

Turn the printer off, then shut the mini PC down normally. No other steps.

---

## Setting up a new machine

Done once per mini PC. Needs an elevated PowerShell.

### 1. Install

```powershell
git clone https://github.com/AmbientOne/photo-booth-printer.git C:\printer
cd C:\printer\print-server
py -m pip install -r requirements.txt
```

The destination folder is up to you -- every script resolves its paths relative
to its own location, so `C:\printers` or anywhere else works. Just keep the
`print-server\`, `photo-booth\` and `scripts\` folders together, and
substitute your own path for `C:\printer` throughout this document.

Python 3.10+ from python.org, with the `py` launcher, is assumed.

Windows blocks all PowerShell scripts by default, so allow local ones once
(this needs no admin rights):

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

`RemoteSigned` still blocks scripts downloaded from the internet while allowing
these, which arrived via `git clone`. Without it every command below fails with
*"running scripts is disabled on this system"*. The scheduled tasks registered
later are unaffected either way -- they invoke PowerShell with an explicit
`-ExecutionPolicy Bypass`, so the booth starts regardless of this setting.

If you downloaded a ZIP from GitHub instead of cloning, Windows also tags every
file as internet-sourced and `RemoteSigned` keeps blocking them. Clear that:

```powershell
Get-ChildItem C:\printer -Recurse -File | Unblock-File
```

To run a single script without changing the policy at all:

```powershell
powershell -ExecutionPolicy Bypass -File .\hotspot.ps1 -Check
```

### 2. Confirm the machine can host a hotspot

```powershell
cd C:\printer\scripts
.\hotspot.ps1 -Check
```

This changes nothing and prints the hotspot state. If it reports that no
usable network profile exists, the whole self-hosted-network approach will not
work on this hardware -- stop here and use a travel router instead (the mini PC
joins it by ethernet; set `PHOTOBOOTH_ADVERTISED_IP` and regenerate the
certificate for that address). Everything below assumes this step passed.

### 3. Generate the certificate

```powershell
py make_cert.py
```

This writes `certs\ca.pem`, `certs\cert.pem` and `certs\key.pem`, all valid for
`192.168.137.1` — the address Windows always assigns to the machine hosting a
mobile hotspot. Because that address never changes, the certificate never needs
regenerating when you move venues.

The CA's own private key is generated in memory and discarded. That matters:
the iPad trusts this CA as a root, and a root whose key still existed on disk
could be used to impersonate any website to that iPad.

### 4. Configure the machine

```powershell
cd C:\printer\scripts
.\install.ps1 -Ssid "AP-02" -Passphrase "choose-something-long" -EnableAutoLogon
```

This disables the hotspot's idle timeout, replaces Windows' overly broad
firewall rules with one scoped to the booth's own subnet, registers the two
startup tasks, and turns on automatic logon.

Automatic logon is what makes "restart the computer" sufficient — without it
the machine stops at the lock screen after a power cut and never starts the
booth. It stores the account password in the registry in clear text, so use a
machine dedicated to the booth.

### 5. Restart, and confirm

```powershell
.\status.ps1
```

Every line should read OK. It also prints the two URLs you need next.

### 6. Provision the iPad

Once per iPad:

1. Join the booth Wi-Fi network.
2. Open `https://192.168.137.1:5443/cert` in Safari. It will warn *"This
   Connection Is Not Private"* -- expected, since the certificate it is about
   to hand you is the very thing that would make it trusted. Tap **Show
   Details** -> **visit this website** -> **Visit Website**, then allow the
   download.

   Use the **https** address, not `http://...:5000/cert`. Current iOS Safari
   upgrades typed addresses to HTTPS, tries TLS against the plain-HTTP port,
   and simply hangs.

   If it still hangs, turn off **iCloud Private Relay** (Settings -> your name
   -> iCloud) and **Limit IP Address Tracking** (Settings -> Wi-Fi -> the (i)
   next to the booth network). Both intercept local-network requests.
3. Settings → General → VPN & Device Management → install the **PhotoBooth**
   profile.
4. Settings → General → About → **Certificate Trust Settings** → turn on full
   trust for *PhotoBooth Local Root*.
5. Open the booth URL that `status.ps1` printed, including the `?k=` token.
   The token is saved in the browser, so later visits don't need it.
6. Share → **Add to Home Screen**, so the operator has one icon to tap.

Optional but worth it: turn on **Guided Access** (Settings → Accessibility) so
guests can't leave the booth app.

### Choosing the network name

Do not call it "PhotoBooth", or anything else that announces what it is. Guests
who see a booth-shaped network name will try to join it, and every attempt is
someone asking you for a password during an event.

Pick something that reads as unconfigured hardware and gets ignored:

- the router's factory SSID, left exactly as it shipped
- `GL-SFT1200-a4f`, `AP-02`, `Net-2G`, `TP-Link_5G`

Better still, hide it entirely: **GL.iNet admin -> Wireless -> Hide SSID**. The
iPad connects fine to a hidden network once the details are saved, and nobody
else can see it exists.

None of this is real security -- the passphrase is the actual lock, and it
should be long. This is about not being noticed in the first place.

### Headless machines

A mini PC with no monitor cannot show you the booth URL, and the token is
generated randomly into `C:\PhotoBooth\token.txt` where nobody can read it.
Choose the token instead, and the URL is knowable from anywhere:

```powershell
.\install-router.ps1 -ServerIP 192.168.8.2 -Subnet 192.168.8.0/24 -Token "yourbooth2026"
```

The installer then prints the full booth URL, and it stays the same across
rebuilds. Letters, numbers, dash and underscore only, since it goes in a URL.

Worth enabling remote access while a monitor is still attached, so you never
need one again (elevated):

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
New-NetFirewallRule -DisplayName "SSH" -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 22 -RemoteAddress 192.168.8.0/24
```

Then from a laptop on the booth network: `ssh KIANA@192.168.8.2`, and
`status.ps1` works over that connection like any other.

Note that once an iPad has been provisioned it stores the token itself, so the
home-screen icon keeps working without the URL. You only need it again when
adding a new device or after clearing Safari data.

### Laptop mode: one click, no auto logon

On a machine that is not dedicated to the booth -- a laptop someone also uses
for other things -- skip `-EnableAutoLogon` and give the operator a button
instead:

```powershell
.\install-shortcut.ps1
```

That puts **Start Photo Booth** on the Desktop. Double-clicking it brings up the
Wi-Fi, starts the print server, checks the printer, and prints a green box when
the booth is ready or a plain-English explanation when it is not. Closing the
window stops the booth.

Also stop the machine sleeping mid-event:

```powershell
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
```

The trade-off is explicit: without auto logon nothing starts by itself, so a
power cut needs a person. Fine when the operator is present and the laptop is
open; not good enough for an unattended mini PC.

### 7. Rehearse the failure

Before the real event, pull the mini PC's power mid-session and turn it back
on. Confirm the booth is serving again about a minute later without anyone
touching a keyboard. That rehearsal is the only real proof the autostart works.

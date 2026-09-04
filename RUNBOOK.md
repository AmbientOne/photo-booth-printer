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

Python 3.10+ from python.org, with the `py` launcher, is assumed.

### 2. Generate the certificate

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

### 3. Configure the machine

```powershell
cd C:\printer\scripts
.\install.ps1 -Ssid "PhotoBooth" -Passphrase "choose-something-long" -EnableAutoLogon
```

This disables the hotspot's idle timeout, replaces Windows' overly broad
firewall rules with one scoped to the booth's own subnet, registers the two
startup tasks, and turns on automatic logon.

Automatic logon is what makes "restart the computer" sufficient — without it
the machine stops at the lock screen after a power cut and never starts the
booth. It stores the account password in the registry in clear text, so use a
machine dedicated to the booth.

### 4. Restart, and confirm

```powershell
.\status.ps1
```

Every line should read OK. It also prints the two URLs you need next.

### 5. Provision the iPad

Once per iPad:

1. Join the booth Wi-Fi network.
2. Open `http://192.168.137.1:5000/cert` in Safari and allow the download.
3. Settings → General → VPN & Device Management → install the **PhotoBooth**
   profile.
4. Settings → General → About → **Certificate Trust Settings** → turn on full
   trust for *PhotoBooth Local Root*.
5. Open the booth URL that `status.ps1` printed, including the `?k=` token.
   The token is saved in the browser, so later visits don't need it.
6. Share → **Add to Home Screen**, so the operator has one icon to tap.

Optional but worth it: turn on **Guided Access** (Settings → Accessibility) so
guests can't leave the booth app.

### 6. Rehearse the failure

Before the real event, pull the mini PC's power mid-session and turn it back
on. Confirm the booth is serving again about a minute later without anyone
touching a keyboard. That rehearsal is the only real proof the autostart works.

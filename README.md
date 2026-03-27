# VeilNet
<<<<<<< HEAD
A self-hosted privacy gateway for your entire network — built on a Raspberry Pi, configured through a local web wizard, and designed to “just work” (most of the time).
=======

turns your raspberry pi into a network-wide privacy thing. ad blocking, encrypted dns, vpn, firewall, the works. theres a web wizard so you dont have to edit config files by hand.

## disclaimer

the goal of veilnet is to make complex network setup accessible without requiring deep technical knowledge.
under the hood, it’s still doing complex things — so when something goes wrong, details really help.
this was built on my own hardware, and while it works there, I can’t guarantee perfectly repeatable results everywhere (or even on my own setup).

if something breaks:
  - include logs
  - include what you tried
  - include anything even slightly useful

“it doesn’t work” is not useful.

this is a personal project, not a product or a support service.

if you want something more polished, more stable, or more feature-complete — please feel free to fork this and take it there.

## what it does

- **Pi-hole** — blocks ads and trackers for everything on your network
- **Unbound** — recursive dns, so no third-party dns server ever sees your queries
- **dnscrypt-proxy** — encrypts dns in transit so your isp cant snoop
- **WireGuard** — routes all your traffic through a vpn
- **nftables** — firewall that actually drops stuff instead of just logging it
- **SSH hardening** — key-only auth, no root login, moves the port so bots stop knocking
- **fail2ban** — bans people who cant type their password right
- **DDNS** — keeps your home ip findable if your isp keeps changing it (duckdns / no-ip / dynu)
- **Prometheus + Grafana** — graphs if youre into that
- **Telegram alerts** — yells at you when the vpn drops or someone ssh's in

---

## quick start

### option 1: the curl pipe (you know what youre doing)

fresh **Raspberry Pi OS Lite 64-bit**, then:

```bash
curl -sSL https://raw.githubusercontent.com/swervingpanda/VeilNet/main/bootstrap.sh | sudo bash
```

then open **http://veilnet.local** on any device on your network.

### option 2: flash the image (everyone else)

1. grab the image from the [releases page](https://github.com/swervingpanda/VeilNet/releases)
2. flash it with [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
3. boot the pi, wait like 30 seconds
4. open **http://veilnet.local** in a browser

> **about the image:** ssh is enabled. default login is `veilnet` / `veilnet`. change the password after first login (`passwd`). the hostname is `veilnet`, so `ssh veilnet@veilnet.local` should work from most devices.

> **windows users:** if `veilnet.local` doesnt work (it probably wont), use the ip address shown on the pi's console or check your router's device list.

---

## network topologies

the wizard asks you how your pi is connected. pick one:

```
Inline (recommended):
  Modem → [Pi] → Router → Devices
  all traffic goes through the pi.
  you need a usb ethernet adapter for the second port.

DNS gateway:
  Router → [Pi] (as DNS server)
  protects devices that use the router's dns.
  easier but not everything goes through it.

Access point:
  [Pi] as Wi-Fi AP → Wireless devices only
  only stuff connected to the pi's wifi is protected.
```

---

## project layout

```
veilnet/
├── bootstrap.sh          # the curl | bash thing
├── requirements.txt
├── app/
│   ├── main.py           # fastapi, routes, middleware
│   ├── detect.py         # figures out what pi you have
│   ├── installer.py      # runs the scripts and streams progress
│   ├── validators.py     # makes sure nobody sends us garbage
│   └── templates/
│       └── index.html    # the whole wizard ui (its one file, sue me)
├── scripts/
│   ├── dns.sh            # pihole, unbound, dnscrypt
│   ├── vpn.sh            # wireguard
│   ├── firewall.sh       # nftables rules
│   ├── hardening.sh      # ssh, fail2ban, auto-updates
│   ├── ddns.sh           # dynamic dns updater
│   ├── monitoring.sh     # prometheus + grafana
│   ├── alerts.sh         # telegram bot
│   └── routing.sh        # nat gateway for inline mode
└── image/
    └── build.sh          # builds a ready-to-flash .img
```

---

## building the image

`image/build.sh` must be run on a Linux system. it depends on qemu, loop devices, and chroot. i have no idea how to make this work on Windows, and i haven't tried.

```bash
sudo bash image/build.sh
```

---

## dev setup

```bash
git clone https://github.com/swervingpanda/VeilNet
cd VeilNet
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8080
```

open http://localhost:8080 — hardware detection returns empty stuff when youre not on a pi, thats fine, the wizard still works.

---

## license

MIT — do whatever you want, credit is nice but i wont chase you down.
>>>>>>> d22532d (initial commit)

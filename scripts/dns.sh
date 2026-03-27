#!/usr/bin/env bash
# sets up the dns stack (pihole, unbound, dnscrypt, or some combo of them)
# spent way too long figuring out which ports go where
set -euo pipefail

ACTION="${1:-}"

case "$ACTION" in

pihole)
  echo "[dns] Installing Pi-hole..."
  export PIHOLE_SKIP_OS_CHECK=true

  # download it to a file first so we can at least check its not garbage
  PIHOLE_INSTALLER="/tmp/pihole-install.sh"
  curl -sSL https://install.pi-hole.net -o "$PIHOLE_INSTALLER"
  if ! grep -q "Pi-hole" "$PIHOLE_INSTALLER"; then
    echo "[dns] ERROR: Downloaded Pi-hole installer does not look valid"
    rm -f "$PIHOLE_INSTALLER"
    exit 1
  fi
  bash "$PIHOLE_INSTALLER" --unattended
  rm -f "$PIHOLE_INSTALLER"
  echo "[dns] Pi-hole installed."
  ;;

unbound)
  echo "[dns] Installing Unbound..."
  apt-get install -y -qq unbound
  # these are the root dns server addresses, they change like once a decade
  curl -sSL https://www.internic.net/domain/named.root \
    -o /var/lib/unbound/root.hints
  cat > /etc/unbound/unbound.conf.d/veilnet.conf <<'EOF'
server:
    verbosity: 0
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: no
    prefer-ip6: no
    root-hints: "/var/lib/unbound/root.hints"
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no
    edns-buffer-size: 1232
    prefetch: yes
    prefetch-key: yes
    num-threads: 1
    so-rcvbuf: 1m
    rrset-roundrobin: yes
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
    private-address: fd00::/8
    private-address: fe80::/10
EOF
  systemctl enable --now unbound
  # make sure it actually works
  sleep 1
  dig google.com @127.0.0.1 -p 5335 +short > /dev/null \
    && echo "[dns] Unbound is resolving correctly on 127.0.0.1:5335" \
    || echo "[dns] WARNING: Unbound test resolution failed — check /etc/unbound/unbound.conf.d/veilnet.conf"
  ;;

dnscrypt)
  echo "[dns] Installing dnscrypt-proxy..."
  ARCH=$(uname -m)
  case "$ARCH" in
    aarch64) DNSCRYPT_ARCH="arm64" ;;
    armv7l)  DNSCRYPT_ARCH="arm"   ;;
    x86_64)  DNSCRYPT_ARCH="x86_64" ;;
    *)       DNSCRYPT_ARCH="arm64" ;;  # hope for the best
  esac

  DNSCRYPT_VER=$(curl -sSf \
    "https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest" \
    | grep -oP '"tag_name": "\K[^"]+' | head -1)

  echo "[dns] Downloading dnscrypt-proxy ${DNSCRYPT_VER} for ${DNSCRYPT_ARCH}..."
  curl -sSfL \
    "https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${DNSCRYPT_VER}/dnscrypt-proxy-linux_${DNSCRYPT_ARCH}-${DNSCRYPT_VER}.tar.gz" \
    -o /tmp/dnscrypt.tar.gz
  tar -xzf /tmp/dnscrypt.tar.gz -C /tmp
  install -m 755 "/tmp/linux-${DNSCRYPT_ARCH}/dnscrypt-proxy" /usr/local/bin/dnscrypt-proxy
  rm -rf /tmp/dnscrypt.tar.gz "/tmp/linux-${DNSCRYPT_ARCH}"

  mkdir -p /etc/dnscrypt-proxy /var/cache/dnscrypt-proxy
  cat > /etc/dnscrypt-proxy/dnscrypt-proxy.toml <<'EOF'
listen_addresses = ['127.0.0.1:5300']
server_names = ['mullvad-adblock-doh', 'quad9-dnscrypt-ip4-filter-pri', 'cloudflare']
ipv6_servers = false
require_dnssec = true
require_nolog = true
require_nofilter = false
max_clients = 250
timeout = 2500
log_level = 0

[sources]
  [sources.'public-resolvers']
  urls = [
    'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md',
    'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md'
  ]
  cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 72
EOF

  cat > /etc/systemd/system/dnscrypt-proxy.service <<'EOF'
[Unit]
Description=dnscrypt-proxy DNS encryption
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dnscrypt-proxy -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now dnscrypt-proxy
  echo "[dns] dnscrypt-proxy running on 127.0.0.1:5300"
  ;;

wire)
  UPSTREAM="${2:-unbound}"
  echo "[dns] Wiring Pi-hole → ${UPSTREAM}..."

  # tell pihole where to send queries
  case "$UPSTREAM" in
    cloudflare)
      # simplest option, just use cloudflare
      pihole -a setdns "1.1.1.1, 1.0.0.1"
      echo "[dns] Pi-hole upstream: Cloudflare (1.1.1.1, 1.0.0.1)"
      ;;
    dnscrypt)
      # pihole asks dnscrypt on 5300, dnscrypt encrypts and sends it out
      pihole -a setdns 127.0.0.1#5300
      echo "[dns] Pi-hole upstream: dnscrypt-proxy (127.0.0.1:5300)"
      ;;
    unbound)
      # pihole asks unbound on 5335, unbound goes to root servers
      pihole -a setdns 127.0.0.1#5335
      echo "[dns] Pi-hole upstream: Unbound (127.0.0.1:5335)"
      ;;
    full)
      # the whole chain: pihole → unbound → dnscrypt
      # gotta tell unbound to forward through dnscrypt instead of going to root servers
      cat > /etc/unbound/unbound.conf.d/veilnet-forward.conf <<'FORWARDEOF'
server:
    # Disable root-hints resolution, forward everything
    root-hints: ""

forward-zone:
    name: "."
    forward-addr: 127.0.0.1@5300
FORWARDEOF
      systemctl restart unbound
      sleep 1
      pihole -a setdns 127.0.0.1#5335
      echo "[dns] Full stack: Pi-hole → Unbound (5335) → dnscrypt-proxy (5300) → encrypted upstream"
      ;;
    *)
      echo "[dns] ERROR: Unknown upstream '${UPSTREAM}'"
      exit 1
      ;;
  esac

  # systemd-resolved likes to squat on port 53, get rid of that
  if systemctl is-active --quiet systemd-resolved; then
    echo "[dns] Disabling systemd-resolved stub listener..."
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/veilnet.conf <<'EOF'
[Resolve]
DNSStubListener=no
EOF
    systemctl restart systemd-resolved
  fi

  # point the system at pihole
  echo "nameserver 127.0.0.1" > /etc/resolv.conf

  # stop dhcp from overwriting resolv.conf every time it renews
  # using the proper config options instead of chattr because thats just rude
  if [[ -f /etc/dhcpcd.conf ]]; then
    if ! grep -q "nohook resolv.conf" /etc/dhcpcd.conf; then
      echo "nohook resolv.conf" >> /etc/dhcpcd.conf
      echo "[dns] Added 'nohook resolv.conf' to /etc/dhcpcd.conf"
    fi
  fi
  # same thing for networkmanager
  if [[ -d /etc/NetworkManager/conf.d ]]; then
    cat > /etc/NetworkManager/conf.d/veilnet-dns.conf <<'EOF'
[main]
dns=none
EOF
    echo "[dns] Set NetworkManager dns=none"
  fi

  echo "[dns] DNS stack wired. Testing resolution..."
  sleep 1
  dig example.com @127.0.0.1 +short > /dev/null \
    && echo "[dns] Resolution test: OK" \
    || echo "[dns] WARNING: Resolution test failed — Pi-hole may still be starting up"
  ;;

*)
  echo "Usage: dns.sh [pihole|unbound|dnscrypt|wire <cloudflare|dnscrypt|unbound|full>]"
  exit 1
  ;;
esac

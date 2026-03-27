#!/usr/bin/env bash
# wireguard vpn setup
# takes a provider name and optionally a pasted config
set -euo pipefail

ACTION="${1:-install}"
VPN_PROVIDER="${VPN_PROVIDER:-custom}"
WG_CONFIG="${WG_CONFIG:-}"

case "$ACTION" in

install)
  echo "[vpn] Installing WireGuard..."
  apt-get install -y -qq wireguard wireguard-tools resolvconf

  # without this nothing gets forwarded
  grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf \
    || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  sysctl -p > /dev/null

  mkdir -p /etc/wireguard
  chmod 700 /etc/wireguard

  if [[ -n "$WG_CONFIG" ]]; then
    # make sure its actually a wireguard config and not random junk
    if ! printf '%s\n' "$WG_CONFIG" | grep -q '\[Interface\]'; then
      echo "[vpn] ERROR: WireGuard config missing [Interface] section"
      exit 1
    fi
    if ! printf '%s\n' "$WG_CONFIG" | grep -q '\[Peer\]'; then
      echo "[vpn] ERROR: WireGuard config missing [Peer] section"
      exit 1
    fi

    echo "[vpn] Writing WireGuard config to /etc/wireguard/wg0.conf..."
    printf '%s\n' "$WG_CONFIG" > /etc/wireguard/wg0.conf
    chmod 600 /etc/wireguard/wg0.conf
    systemctl enable --now wg-quick@wg0
    sleep 2
    if wg show wg0 > /dev/null 2>&1; then
      echo "[vpn] WireGuard wg0 is up."
      CURRENT_IP=$(curl -sSf --max-time 5 https://ifconfig.me 2>/dev/null || echo "unknown")
      echo "[vpn] Current external IP: ${CURRENT_IP}"
    else
      echo "[vpn] WARNING: WireGuard failed to start. Check your config at /etc/wireguard/wg0.conf"
    fi
  else
    echo "[vpn] No config provided. WireGuard is installed but not configured."
    echo "[vpn] Place your provider's .conf at /etc/wireguard/wg0.conf then run:"
    echo "[vpn]   systemctl enable --now wg-quick@wg0"
    # tell them where to get a config for their provider
    case "$VPN_PROVIDER" in
      mullvad)  echo "[vpn] Get config: https://mullvad.net/account/wireguard-config" ;;
      proton)   echo "[vpn] Get config: https://protonvpn.com/support/wireguard-manual-macos-linux" ;;
      nordvpn)  echo "[vpn] Get config: https://nordvpn.com/servers/tools (select WireGuard)" ;;
      airvpn)   echo "[vpn] Get config: https://airvpn.org/generator (select WireGuard)" ;;
      *)        echo "[vpn] Get your WireGuard .conf from your VPN provider's dashboard." ;;
    esac
  fi

  # watchdog: if wg0 dies, bring it back
  cat > /usr/local/bin/veilnet-vpn-watchdog <<'EOF'
#!/usr/bin/env bash
if ! wg show wg0 > /dev/null 2>&1; then
  logger "VeilNet: wg0 is down, attempting restart"
  systemctl restart wg-quick@wg0
fi
EOF
  chmod +x /usr/local/bin/veilnet-vpn-watchdog

  # check every 2 minutes. the alerts script replaces this with a fancier one
  cat > /etc/cron.d/veilnet-vpn-watchdog <<'EOF'
*/2 * * * * root /usr/local/bin/veilnet-vpn-watchdog
EOF

  echo "[vpn] VPN watchdog installed — wg0 will auto-restart if it drops."
  ;;

*)
  echo "Usage: vpn.sh install"
  exit 1
  ;;
esac

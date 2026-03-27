#!/usr/bin/env bash
# sets up nat routing so the pi acts as an inline gateway
# modem → pi → router, all traffic goes through us
set -euo pipefail

ACTION="${1:-inline}"
WAN_IFACE="${WAN_IFACE:-eth0}"
LAN_IFACE="${LAN_IFACE:-eth1}"

# sanity check the interface names
validate_iface() {
  local name="$1" value="$2"
  if [[ ! "$value" =~ ^[a-zA-Z0-9_-]{1,15}$ ]]; then
    echo "[routing] ERROR: Invalid ${name}: '${value}'"
    exit 1
  fi
}

validate_iface "WAN_IFACE" "$WAN_IFACE"
validate_iface "LAN_IFACE" "$LAN_IFACE"

case "$ACTION" in

inline)
  echo "[routing] Configuring inline NAT gateway (${LAN_IFACE} → ${WAN_IFACE})..."

  # ip forwarding, kinda important
  grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf \
    || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  sysctl -w net.ipv4.ip_forward=1

  # set up dhcp on the lan side if nothing else is doing it
  if ! systemctl is-active --quiet dnsmasq && ! systemctl is-active --quiet isc-dhcp-server; then
    echo "[routing] Installing dnsmasq for DHCP on ${LAN_IFACE}..."
    apt-get install -y -qq dnsmasq

    # see if the lan interface already has an ip
    LAN_IP=$(ip -4 addr show "${LAN_IFACE}" | grep -oP '(?<=inet )[\d.]+' | head -1)
    if [[ -z "$LAN_IP" ]]; then
      LAN_IP="192.168.100.1"
      ip addr add "${LAN_IP}/24" dev "${LAN_IFACE}"
      # make it stick after reboot
      cat >> /etc/dhcpcd.conf <<EOF

interface ${LAN_IFACE}
static ip_address=${LAN_IP}/24
EOF
    fi

    SUBNET=$(echo "$LAN_IP" | cut -d. -f1-3)

    cat > /etc/dnsmasq.d/veilnet-lan.conf <<EOF
interface=${LAN_IFACE}
bind-interfaces
dhcp-range=${SUBNET}.10,${SUBNET}.250,24h
dhcp-option=option:router,${LAN_IP}
dhcp-option=option:dns-server,${LAN_IP}
server=127.0.0.1
no-resolv
EOF
    systemctl enable --now dnsmasq
    echo "[routing] DHCP server running on ${LAN_IFACE} (${LAN_IP}/24)"
  fi

  echo "[routing] Inline gateway configured."
  echo "[routing] LAN clients on ${LAN_IFACE} will be routed through ${WAN_IFACE}."
  ;;

*)
  echo "Usage: routing.sh [inline]"
  exit 1
  ;;
esac

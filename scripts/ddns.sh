#!/usr/bin/env bash
# sets up ddns so your home ip stays reachable
# supports duckdns, noip, dynu. add more if you want i guess
set -euo pipefail

DDNS_PROVIDER="${DDNS_PROVIDER:-duckdns}"
DDNS_TOKEN="${DDNS_TOKEN:-}"
DDNS_DOMAIN="${DDNS_DOMAIN:-}"

[[ -z "$DDNS_TOKEN" ]]  && { echo "[ddns] ERROR: DDNS_TOKEN not set"; exit 1; }
[[ -z "$DDNS_DOMAIN" ]] && { echo "[ddns] ERROR: DDNS_DOMAIN not set"; exit 1; }

# dont let anyone sneak shell metacharacters in here
validate_input() {
  local name="$1" value="$2"
  if [[ "$value" =~ [^a-zA-Z0-9_.:/+=-] ]]; then
    echo "[ddns] ERROR: ${name} contains disallowed characters"
    exit 1
  fi
}

validate_input "DDNS_PROVIDER" "$DDNS_PROVIDER"
validate_input "DDNS_TOKEN" "$DDNS_TOKEN"
# domain can have hyphens and dots, thats fine
if [[ "$DDNS_DOMAIN" =~ [^a-zA-Z0-9._-] ]]; then
  echo "[ddns] ERROR: DDNS_DOMAIN contains disallowed characters"
  exit 1
fi

echo "[ddns] Configuring DDNS provider: ${DDNS_PROVIDER}"

mkdir -p /opt/veilnet/ddns

# keep the credentials in their own file, not inline in the script
cat > /opt/veilnet/ddns/credentials.conf <<CREDEOF
DDNS_TOKEN='${DDNS_TOKEN}'
DDNS_DOMAIN='${DDNS_DOMAIN}'
CREDEOF
chmod 600 /opt/veilnet/ddns/credentials.conf

case "$DDNS_PROVIDER" in

duckdns)
  # duckdns just wants the subdomain part, not the full domain
  SUBDOMAIN="${DDNS_DOMAIN%%.*}"
  # rewrite creds with the subdomain added
  cat > /opt/veilnet/ddns/credentials.conf <<CREDEOF
DDNS_TOKEN='${DDNS_TOKEN}'
DDNS_DOMAIN='${DDNS_DOMAIN}'
DDNS_SUBDOMAIN='${SUBDOMAIN}'
CREDEOF
  chmod 600 /opt/veilnet/ddns/credentials.conf

  cat > /opt/veilnet/ddns/update.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /opt/veilnet/ddns/credentials.conf
RESPONSE=$(curl -sSf "https://www.duckdns.org/update?domains=${DDNS_SUBDOMAIN}&token=${DDNS_TOKEN}&ip=")
if echo "$RESPONSE" | grep -q "^OK"; then
  logger "VeilNet DDNS: updated ${DDNS_SUBDOMAIN}.duckdns.org successfully"
else
  logger "VeilNet DDNS ERROR: $RESPONSE"
fi
EOF
  echo "[ddns] DuckDNS configured for ${SUBDOMAIN}.duckdns.org"
  ;;

noip)
  apt-get install -y -qq curl
  cat > /opt/veilnet/ddns/update.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /opt/veilnet/ddns/credentials.conf
RESPONSE=$(curl -sSf "https://dynupdate.no-ip.com/nic/update?hostname=${DDNS_DOMAIN}" \
  --user "${DDNS_TOKEN}" \
  -A "VeilNet/1.0 admin@veilnet.local")
logger "VeilNet DDNS (No-IP): $RESPONSE"
EOF
  echo "[ddns] No-IP configured for ${DDNS_DOMAIN}"
  ;;

dynu)
  cat > /opt/veilnet/ddns/update.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /opt/veilnet/ddns/credentials.conf
IP=$(curl -sSf https://api.ipify.org)
RESPONSE=$(curl -sSf "https://api.dynu.com/nic/update?hostname=${DDNS_DOMAIN}&myip=${IP}&password=${DDNS_TOKEN}")
logger "VeilNet DDNS (Dynu): $RESPONSE"
EOF
  echo "[ddns] Dynu configured for ${DDNS_DOMAIN}"
  ;;

*)
  echo "[ddns] ERROR: Unknown provider '${DDNS_PROVIDER}'"
  exit 1
  ;;
esac

chmod +x /opt/veilnet/ddns/update.sh

# run it once now to see if it works
echo "[ddns] Running initial update..."
bash /opt/veilnet/ddns/update.sh

# then every 5 minutes forever
cat > /etc/cron.d/veilnet-ddns <<'EOF'
*/5 * * * * root /opt/veilnet/ddns/update.sh
EOF

echo "[ddns] DDNS updater installed. Updates every 5 minutes."

#!/usr/bin/env bash
# telegram bot that yells at you when stuff breaks
# also does ssh login notifications and high load warnings
set -euo pipefail

ACTION="${1:-telegram}"
TG_TOKEN="${TG_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

[[ -z "$TG_TOKEN" ]]   && { echo "[alerts] ERROR: TG_TOKEN not set";   exit 1; }
[[ -z "$TG_CHAT_ID" ]] && { echo "[alerts] ERROR: TG_CHAT_ID not set"; exit 1; }

# make sure these look like actual telegram credentials
if [[ ! "$TG_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
  echo "[alerts] ERROR: TG_TOKEN format invalid (expected digits:alphanumeric)"
  exit 1
fi

if [[ ! "$TG_CHAT_ID" =~ ^-?[0-9]+$ ]]; then
  echo "[alerts] ERROR: TG_CHAT_ID format invalid (expected numeric)"
  exit 1
fi

echo "[alerts] Setting up Telegram alert system..."

mkdir -p /etc/veilnet
cat > /etc/veilnet/telegram.conf <<EOF
TG_TOKEN=${TG_TOKEN}
TG_CHAT_ID=${TG_CHAT_ID}
EOF
chmod 600 /etc/veilnet/telegram.conf

# the actual send function. uses --data-urlencode so special chars in messages dont break it
cat > /usr/local/bin/veilnet-alert <<'EOF'
#!/usr/bin/env bash
source /etc/veilnet/telegram.conf
HOSTNAME=$(hostname)
MSG="[${HOSTNAME}] $1"
curl -sSf -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TG_CHAT_ID}" \
  --data-urlencode "text=${MSG}" \
  --data-urlencode "parse_mode=HTML" \
  > /dev/null 2>&1 || logger "VeilNet: Telegram alert failed for: $1"
EOF
chmod +x /usr/local/bin/veilnet-alert

# see if it actually works
echo "[alerts] Testing Telegram connection..."
if /usr/local/bin/veilnet-alert "VeilNet is online and monitoring your network."; then
  echo "[alerts] Telegram test message sent successfully."
else
  echo "[alerts] WARNING: Could not send Telegram test message. Check your token and chat ID."
fi

# get rid of the dumb basic watchdog from vpn.sh, this one is better
rm -f /etc/cron.d/veilnet-vpn-watchdog

# vpn watchdog that actually tells you whats happening
cat > /usr/local/bin/veilnet-vpn-alert <<'EOF'
#!/usr/bin/env bash
if ! wg show wg0 > /dev/null 2>&1; then
  /usr/local/bin/veilnet-alert "VPN (wg0) is DOWN — attempting restart"
  systemctl restart wg-quick@wg0 && \
    /usr/local/bin/veilnet-alert "VPN (wg0) restarted successfully" || \
    /usr/local/bin/veilnet-alert "VPN (wg0) restart FAILED — manual intervention needed"
fi
EOF
chmod +x /usr/local/bin/veilnet-vpn-alert

# ssh login alerts via pam
SSH_PAM_LINE='session optional pam_exec.so /usr/local/bin/veilnet-ssh-alert'
if ! grep -q "veilnet-ssh-alert" /etc/pam.d/sshd; then
  echo "$SSH_PAM_LINE" >> /etc/pam.d/sshd
fi

cat > /usr/local/bin/veilnet-ssh-alert <<'EOF'
#!/usr/bin/env bash
[[ "$PAM_TYPE" == "open_session" ]] || exit 0
/usr/local/bin/veilnet-alert "SSH login: ${PAM_USER} from ${PAM_RHOST}"
EOF
chmod +x /usr/local/bin/veilnet-ssh-alert

# tell me if the pi is struggling
cat > /usr/local/bin/veilnet-load-alert <<'EOF'
#!/usr/bin/env bash
LOAD=$(cat /proc/loadavg | awk '{print $1}')
CORES=$(nproc)
THRESHOLD=$(echo "$CORES * 2" | bc)
if (( $(echo "$LOAD > $THRESHOLD" | bc -l) )); then
  /usr/local/bin/veilnet-alert "High load: ${LOAD} (${CORES} cores)"
fi
EOF
chmod +x /usr/local/bin/veilnet-load-alert

cat > /etc/cron.d/veilnet-alerts <<'EOF'
# vpn check every 2 min
*/2 * * * * root /usr/local/bin/veilnet-vpn-alert 2>/dev/null

# load check every 10 min
*/10 * * * * root /usr/local/bin/veilnet-load-alert 2>/dev/null

# hey im still alive
0 8 * * * root /usr/local/bin/veilnet-alert "VeilNet daily check-in — all systems operational" 2>/dev/null
EOF

echo "[alerts] Telegram alerts configured:"
echo "[alerts]   - SSH login notifications"
echo "[alerts]   - VPN drop detection + auto-restart alerts"
echo "[alerts]   - High load warnings"
echo "[alerts]   - Daily alive ping at 8am"

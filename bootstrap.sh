#!/usr/bin/env bash
# the one-liner install script
# curl it, pipe to bash, pray
# (its fine, we check for root and stuff)
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[VeilNet]${NC} $1"; }
warn()  { echo -e "${YELLOW}[VeilNet]${NC} $1"; }
die()   { echo -e "${RED}[VeilNet]${NC} $1"; exit 1; }
hr()    { echo -e "${CYAN}────────────────────────────────────────────${NC}"; }

[[ $EUID -ne 0 ]] && die "Run as root: curl -sSL ... | sudo bash"

hr
echo -e "${CYAN}"
cat <<'LOGO'
 __     __   _ _ _   _      _
 \ \   / /__(_) | \ | | ___| |_
  \ \ / / _ \ | |  \| |/ _ \ __|
   \ V /  __/ | | |\  |  __/ |_
    \_/ \___|_|_|_| \_|\___|\__|


 Privacy Gateway — Setup Wizard
LOGO
echo -e "${NC}"
hr
echo ""

info "Checking system..."
[[ $(uname -m) =~ ^(aarch64|armv7l) ]] || warn "Not a Raspberry Pi? Proceeding anyway."
grep -qi "raspberry" /proc/cpuinfo 2>/dev/null && info "Raspberry Pi detected." || true

info "Installing dependencies..."
apt-get update -qq
apt-get install -y -qq \
    python3 python3-pip python3-venv \
    nginx avahi-daemon avahi-utils \
    git curl wget net-tools iproute2 \
    lsb-release sudo

info "Setting hostname to 'veilnet'..."
hostnamectl set-hostname veilnet
# add or update the hosts entry without duplicating it
if grep -q "^127\.0\.1\.1" /etc/hosts; then
  sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tveilnet/' /etc/hosts
else
  echo "127.0.1.1	veilnet" >> /etc/hosts
fi
systemctl enable --now avahi-daemon
info "This device is now reachable at http://veilnet.local"

INSTALL_DIR=/opt/veilnet
info "Installing VeilNet to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"

# in dev you just drop your source in /tmp/veilnet-src
# in prod it pulls from github
if [[ -d "/tmp/veilnet-src" ]]; then
    cp -r /tmp/veilnet-src/. "${INSTALL_DIR}/"
    info "Installed from local source."
else
    info "Pulling latest release..."
    curl -sSL "https://github.com/swervingpanda/VeilNet/archive/refs/heads/main.tar.gz" \
        -o /tmp/veilnet.tar.gz
    tar -xzf /tmp/veilnet.tar.gz -C "${INSTALL_DIR}" --strip-components=1
fi

info "Setting up Python environment..."
python3 -m venv "${INSTALL_DIR}/.venv"
"${INSTALL_DIR}/.venv/bin/pip" install -q --upgrade pip
"${INSTALL_DIR}/.venv/bin/pip" install -q fastapi uvicorn jinja2 python-multipart psutil

# nginx sits in front and only lets lan traffic through
info "Configuring nginx (port 80 → 8080, LAN-only)..."
cat > /etc/nginx/sites-available/veilnet <<'EOF'
server {
    listen 80 default_server;
    server_name veilnet.local veilnet _;

    # only local network
    allow 10.0.0.0/8;
    allow 172.16.0.0/12;
    allow 192.168.0.0/16;
    allow 127.0.0.0/8;
    allow 169.254.0.0/16;
    allow ::1;
    allow fe80::/10;
    allow fc00::/7;
    deny all;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection '';
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_cache_bypass $http_upgrade;
        # sse needs buffering off or it just sits there
        proxy_buffering off;
        proxy_read_timeout 3600s;
        chunked_transfer_encoding on;
    }
}
EOF
ln -sf /etc/nginx/sites-available/veilnet /etc/nginx/sites-enabled/veilnet
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable --now nginx

info "Registering VeilNet as a system service..."
cat > /etc/systemd/system/veilnet.service <<EOF
[Unit]
Description=VeilNet Privacy Gateway Wizard
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8080
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now veilnet

# get the ip for windows users who cant do mdns
sleep 2
LOCAL_IP=$(hostname -I | awk '{print $1}')

hr
echo ""
echo -e "${GREEN}  VeilNet is running!${NC}"
echo ""
echo -e "  Open a browser on any device on this network and go to:"
echo ""
echo -e "  ${CYAN}  http://veilnet.local${NC}    (Mac, Linux, iPhone, Android)"
echo -e "  ${CYAN}  http://${LOCAL_IP}${NC}       (Windows fallback)"
echo ""
hr
echo ""

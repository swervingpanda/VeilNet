#!/usr/bin/env bash
# builds a flashable .img file with everything pre-installed
# run this on a normal linux pc, not on the pi
# needs qemu to pretend to be an arm cpu
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[build]${NC} $1"; }
warn()  { echo -e "${YELLOW}[build]${NC} $1"; }
die()   { echo -e "${RED}[build]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && die "Run as root"

OUTPUT="${1:-/tmp/veilnet.img}"
WORK_DIR="$(mktemp -d /tmp/veilnet-build.XXXXXX)"
MOUNT_DIR="${WORK_DIR}/mnt"
VEILNET_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BASE_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images"
RASPIOS_IMG_XZ=""

# clean up loop devices and mounts when we're done or if something breaks
cleanup() {
  info "Cleaning up..."
  umount "${MOUNT_DIR}/boot/firmware" 2>/dev/null || true
  umount "${MOUNT_DIR}/proc"          2>/dev/null || true
  umount "${MOUNT_DIR}/sys"           2>/dev/null || true
  umount "${MOUNT_DIR}/dev/pts"       2>/dev/null || true
  umount "${MOUNT_DIR}/dev"           2>/dev/null || true
  umount "${MOUNT_DIR}"               2>/dev/null || true
  [[ -n "${LOOP_DEV:-}" ]] && losetup -d "${LOOP_DEV}" 2>/dev/null || true
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

info "Checking build dependencies..."
for dep in qemu-aarch64-static systemd-nspawn wget xz parted; do
  command -v "$dep" > /dev/null 2>&1 || die "Missing: $dep — install with: apt-get install qemu-user-static systemd-container wget xz-utils parted"
done

info "Fetching latest Raspberry Pi OS Lite 64-bit..."
LATEST_DIR=$(wget -qO- "${BASE_URL}/" | grep -oP 'raspios_lite_arm64-\d{4}-\d{2}-\d{2}/' | sort -V | tail -1)
LATEST_URL="${BASE_URL}/${LATEST_DIR}"
IMG_XZ=$(wget -qO- "${LATEST_URL}" | grep -oP '\d{4}-\d{2}-\d{2}-raspios-\w+-arm64-lite\.img\.xz' | head -1)
RASPIOS_IMG_XZ="${WORK_DIR}/${IMG_XZ}"

info "Downloading: ${IMG_XZ}"
wget -q --show-progress "${LATEST_URL}${IMG_XZ}" -O "${RASPIOS_IMG_XZ}"

info "Decompressing..."
xz -d "${RASPIOS_IMG_XZ}"
RASPIOS_IMG="${RASPIOS_IMG_XZ%.xz}"

# make room for our stuff
info "Expanding image by 512MB for VeilNet..."
truncate -s +512M "${RASPIOS_IMG}"
LOOP_DEV=$(losetup -f --show -P "${RASPIOS_IMG}")
ROOT_PART="${LOOP_DEV}p2"
parted -s "${LOOP_DEV}" resizepart 2 100%
e2fsck -f -y "${ROOT_PART}" || true
resize2fs "${ROOT_PART}"

mkdir -p "${MOUNT_DIR}"
mount "${ROOT_PART}" "${MOUNT_DIR}"
mount "${LOOP_DEV}p1" "${MOUNT_DIR}/boot/firmware" 2>/dev/null \
  || mount "${LOOP_DEV}p1" "${MOUNT_DIR}/boot" 2>/dev/null || true

info "Setting up arm64 emulation..."
cp /usr/bin/qemu-aarch64-static "${MOUNT_DIR}/usr/bin/"

info "Copying VeilNet source..."
mkdir -p "${MOUNT_DIR}/opt/veilnet"
rsync -a --exclude='.venv' --exclude='__pycache__' --exclude='*.pyc' \
  "${VEILNET_SRC}/" "${MOUNT_DIR}/opt/veilnet/"

# this is where it gets slow — installing stuff inside the arm image via qemu
info "Running bootstrap inside image (this takes a while)..."

mount --bind /proc    "${MOUNT_DIR}/proc"
mount --bind /sys     "${MOUNT_DIR}/sys"
mount --bind /dev     "${MOUNT_DIR}/dev"
mount --bind /dev/pts "${MOUNT_DIR}/dev/pts"

# need dns working inside the chroot
cp /etc/resolv.conf "${MOUNT_DIR}/etc/resolv.conf"

chroot "${MOUNT_DIR}" /usr/bin/qemu-aarch64-static /bin/bash <<'CHROOT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PIHOLE_SKIP_OS_CHECK=true

echo "[chroot] Updating packages..."
apt-get update -qq
apt-get install -y -qq \
    python3 python3-pip python3-venv \
    nginx avahi-daemon avahi-utils \
    git curl wget net-tools iproute2

echo "[chroot] Setting hostname to veilnet..."
echo "veilnet" > /etc/hostname
sed -i 's/raspberrypi/veilnet/g' /etc/hosts
# dont duplicate the hosts entry
if grep -q "^127\.0\.1\.1" /etc/hosts; then
  sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tveilnet/' /etc/hosts
else
  echo "127.0.1.1	veilnet" >> /etc/hosts
fi

echo "[chroot] Installing Python dependencies..."
python3 -m venv /opt/veilnet/.venv
/opt/veilnet/.venv/bin/pip install -q --upgrade pip
/opt/veilnet/.venv/bin/pip install -q fastapi uvicorn jinja2 python-multipart psutil

echo "[chroot] Configuring nginx (LAN-only)..."
cat > /etc/nginx/sites-available/veilnet <<'NGINX'
server {
    listen 80 default_server;
    server_name veilnet.local veilnet _;

    # local network only
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
        proxy_set_header Connection '';
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        chunked_transfer_encoding on;
    }
}
NGINX
ln -sf /etc/nginx/sites-available/veilnet /etc/nginx/sites-enabled/veilnet
rm -f /etc/nginx/sites-enabled/default

echo "[chroot] Registering systemd services..."
cat > /etc/systemd/system/veilnet.service <<'SERVICE'
[Unit]
Description=VeilNet Privacy Gateway Wizard
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/veilnet
ExecStart=/opt/veilnet/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8080
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable veilnet nginx avahi-daemon ssh

# raspberry pi os no longer ships with a default user
# gotta make one or nobody can log in
echo "[chroot] Creating default user 'veilnet'..."
useradd -m -s /bin/bash -G sudo veilnet
echo "veilnet:veilnet" | chpasswd

echo "[chroot] Done."
CHROOT

# enable ssh by dropping the flag file in the boot partition
# pi os checks for this on first boot
info "Enabling SSH..."
BOOT_DIR=""
if mountpoint -q "${MOUNT_DIR}/boot/firmware"; then
  BOOT_DIR="${MOUNT_DIR}/boot/firmware"
elif mountpoint -q "${MOUNT_DIR}/boot"; then
  BOOT_DIR="${MOUNT_DIR}/boot"
fi
if [[ -n "$BOOT_DIR" ]]; then
  touch "${BOOT_DIR}/ssh"
fi

# print the ip on first boot so people can find it
info "Adding first-boot IP display..."
cat > "${MOUNT_DIR}/usr/local/bin/veilnet-firstboot" <<'EOF'
#!/usr/bin/env bash
# give the network a sec to come up
sleep 8
IP=$(hostname -I | awk '{print $1}')
echo ""
echo "============================================"
echo "  VeilNet is ready!"
echo ""
echo "  Open a browser and go to:"
echo "    http://veilnet.local    (most devices)"
echo "    http://${IP}            (Windows fallback)"
echo "============================================"
echo ""
EOF
chmod +x "${MOUNT_DIR}/usr/local/bin/veilnet-firstboot"

cat > "${MOUNT_DIR}/etc/systemd/system/veilnet-firstboot.service" <<'EOF'
[Unit]
Description=VeilNet first-boot message
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/veilnet-firstboot
StandardOutput=console
TTYPath=/dev/tty1

[Install]
WantedBy=multi-user.target
EOF
chroot "${MOUNT_DIR}" /usr/bin/qemu-aarch64-static /bin/bash -c \
  "systemctl enable veilnet-firstboot"

info "Cleaning up chroot..."
rm -f "${MOUNT_DIR}/usr/bin/qemu-aarch64-static"
rm -f "${MOUNT_DIR}/etc/resolv.conf"
# put the symlink back
chroot "${MOUNT_DIR}" /bin/bash -c \
  "ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf" 2>/dev/null || true

info "Finalising image..."
sync

cp "${RASPIOS_IMG}" "${OUTPUT}"

info "Done!"
echo ""
echo -e "${CYAN}  VeilNet image: ${OUTPUT}${NC}"
echo -e "  Flash with Raspberry Pi Imager or:"
echo -e "  ${CYAN}  sudo dd if=${OUTPUT} of=/dev/sdX bs=4M status=progress${NC}"
echo ""

#!/usr/bin/env bash
# makes things harder to break into
# ssh lockdown, auto updates, fail2ban
set -euo pipefail

ACTION="${1:-}"
SSH_PORT="${SSH_PORT:-2222}"

case "$ACTION" in

ssh)
  echo "[ssh] Hardening SSH configuration..."
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.veilnet-bak

  # look for ssh keys before we disable password login
  # because locking yourself out of your own pi is not fun (ask me how i know)
  HAS_KEYS=false
  for keyfile in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    if [[ -f "$keyfile" ]] && [[ -s "$keyfile" ]]; then
      HAS_KEYS=true
      echo "[ssh] Found SSH key: ${keyfile}"
      break
    fi
  done

  declare -A SSH_SETTINGS=(
    ["Port"]="$SSH_PORT"
    ["PermitRootLogin"]="no"
    ["PubkeyAuthentication"]="yes"
    ["AuthorizedKeysFile"]=".ssh/authorized_keys"
    ["PermitEmptyPasswords"]="no"
    ["ChallengeResponseAuthentication"]="no"
    ["UsePAM"]="yes"
    ["X11Forwarding"]="no"
    ["AllowAgentForwarding"]="no"
    ["MaxAuthTries"]="3"
    ["LoginGraceTime"]="30"
    ["ClientAliveInterval"]="300"
    ["ClientAliveCountMax"]="2"
  )

  # only kill password auth if theres actually a key to use instead
  if [[ "$HAS_KEYS" == "true" ]]; then
    SSH_SETTINGS["PasswordAuthentication"]="no"
    echo "[ssh] SSH keys found — disabling password authentication."
  else
    echo "[ssh] WARNING: No SSH authorized_keys found. Keeping password authentication enabled to prevent lockout."
    echo "[ssh] Add your SSH public key to ~/.ssh/authorized_keys and then manually disable password auth."
  fi

  for key in "${!SSH_SETTINGS[@]}"; do
    val="${SSH_SETTINGS[$key]}"
    if grep -qE "^#?${key}\b" /etc/ssh/sshd_config; then
      sed -i "s|^#\?${key}\b.*|${key} ${val}|" /etc/ssh/sshd_config
    else
      echo "${key} ${val}" >> /etc/ssh/sshd_config
    fi
  done

  # check our work before reloading
  sshd -t \
    && echo "[ssh] Config valid." \
    || { echo "[ssh] ERROR: sshd config invalid. Restoring backup."; cp /etc/ssh/sshd_config.veilnet-bak /etc/ssh/sshd_config; exit 1; }

  systemctl reload ssh
  echo "[ssh] SSH hardened. Port: ${SSH_PORT}."
  if [[ "$HAS_KEYS" == "true" ]]; then
    echo "[ssh] Password auth: disabled."
  else
    echo "[ssh] Password auth: still enabled (no keys found)."
  fi
  ;;

auto_updates)
  echo "[updates] Configuring unattended-upgrades..."
  apt-get install -y -qq unattended-upgrades apt-listchanges

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Download-Upgradeable-Packages "1";
EOF

  cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF

  systemctl enable --now unattended-upgrades
  unattended-upgrade --dry-run 2>&1 | tail -5
  echo "[updates] Automatic security updates configured."
  ;;

fail2ban)
  echo "[fail2ban] Installing fail2ban..."
  apt-get install -y -qq fail2ban

  # one jail for ssh, aggressive mode catches more stuff
  # used to have a separate sshd-ddos jail but that just bans people twice
  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime   = 3600
findtime  = 600
maxretry  = 3
backend   = systemd
ignoreip  = 127.0.0.1/8 ::1

[sshd]
enabled   = true
port      = ${SSH_PORT}
filter    = sshd
mode      = aggressive
maxretry  = 3
bantime   = 86400
EOF

  # also watch pihole login attempts
  cat > /etc/fail2ban/filter.d/pihole-auth.conf <<'EOF'
[Definition]
failregex = ^.*\[AUTH\] Invalid.*from <HOST>.*$
ignoreregex =
EOF

  cat >> /etc/fail2ban/jail.local <<'EOF'

[pihole-auth]
enabled  = true
filter   = pihole-auth
logpath  = /var/log/pihole.log
maxretry = 5
bantime  = 3600
EOF

  systemctl enable --now fail2ban
  sleep 1
  fail2ban-client status 2>/dev/null | grep "Jail list" || true
  echo "[fail2ban] fail2ban running."
  ;;

*)
  echo "Usage: hardening.sh [ssh|auto_updates|fail2ban]"
  exit 1
  ;;
esac

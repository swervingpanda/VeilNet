#!/usr/bin/env bash
# prometheus + grafana for people who like graphs
# takes a while to install, worth it though
set -euo pipefail

echo "[monitoring] Installing Prometheus node exporter..."
apt-get install -y -qq prometheus-node-exporter

echo "[monitoring] Installing Grafana..."
# add their apt repo
curl -sSfL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list
apt-get update -qq
apt-get install -y -qq grafana

# tell grafana where prometheus is
mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/prometheus.yaml <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: http://localhost:9090
    isDefault: true
    editable: false
EOF

# set up dashboard auto-loading
mkdir -p /etc/grafana/provisioning/dashboards
cat > /etc/grafana/provisioning/dashboards/veilnet.yaml <<'EOF'
apiVersion: 1
providers:
  - name: VeilNet
    folder: VeilNet
    type: file
    options:
      path: /etc/grafana/dashboards
EOF

mkdir -p /etc/grafana/dashboards

# prometheus itself (scrapes node_exporter)
apt-get install -y -qq prometheus

# tell prometheus what to scrape
cat > /etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']

  - job_name: 'pihole'
    static_configs:
      - targets: ['localhost:9617']
    metrics_path: /metrics
EOF

systemctl enable --now prometheus prometheus-node-exporter grafana-server

sleep 3
systemctl is-active prometheus     && echo "[monitoring] Prometheus running." || echo "[monitoring] WARNING: Prometheus not started"
systemctl is-active grafana-server && echo "[monitoring] Grafana running." || echo "[monitoring] WARNING: Grafana not started"

# generate a random password because leaving it as admin/admin is embarrassing
echo "[monitoring] Setting random Grafana admin password..."
GRAFANA_PASS=$(openssl rand -base64 16)

# grafana-cli needs the server running, give it a sec
for i in 1 2 3; do
  if grafana-cli admin reset-admin-password "$GRAFANA_PASS" 2>/dev/null; then
    break
  fi
  sleep 2
done

# save it somewhere findable
mkdir -p /etc/veilnet
cat > /etc/veilnet/grafana-admin.txt <<EOF
Grafana admin password: ${GRAFANA_PASS}
URL: http://veilnet.local:3000
User: admin
EOF
chmod 600 /etc/veilnet/grafana-admin.txt

echo "[monitoring] Grafana running at http://veilnet.local:3000"
echo "[monitoring] Admin password saved to /etc/veilnet/grafana-admin.txt"
echo "[monitoring] Grafana admin password: ${GRAFANA_PASS}"

#!/bin/bash
# Idempotent setup of the finops-backend VM (Debian 13). Run as the cloud-init user:
#   ssh finops@<ip> 'sudo bash -s' < infra/bootstrap.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LAN_CIDR="${LAN_CIDR:-192.168.1.0/24}"
APP_USER="${APP_USER:-finops}"
APP_DIR=/opt/finops

echo "→ packages"
apt-get update -q
apt-get install -y -q --no-install-recommends \
  qemu-guest-agent ca-certificates curl gnupg nftables unattended-upgrades \
  docker.io docker-cli docker-compose rsync jq
systemctl enable --now qemu-guest-agent docker

echo "→ automatic security updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

echo "→ app user and directory"
usermod -aG docker "$APP_USER"
install -d -o "$APP_USER" -g "$APP_USER" -m 0750 "$APP_DIR"

echo "→ Tailscale"
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list
  apt-get update -q
  apt-get install -y -q tailscale
fi
systemctl enable --now tailscaled

echo "→ firewall (nftables): SSH from LAN + tailnet; everything else inbound dropped"
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif lo accept
    meta l4proto { icmp, ipv6-icmp } accept
    udp dport 41641 accept comment "tailscale direct connections"
    iifname "tailscale0" accept
    ip saddr $LAN_CIDR tcp dport 22 accept
  }
  chain forward { type filter hook forward priority 0; policy accept; }
  chain output { type filter hook output priority 0; policy accept; }
}
EOF
systemctl enable --now nftables
nft -f /etc/nftables.conf
# Docker manages its own NAT/forward rules; restart it so they're re-added after the flush.
systemctl restart docker

echo "→ done"
echo "   docker: $(docker --version)"
echo "   compose: $(docker-compose version --short 2>/dev/null || docker compose version --short)"
echo "   tailscale: $(tailscale version | head -1) — state: $(tailscale status --json | jq -r .BackendState)"

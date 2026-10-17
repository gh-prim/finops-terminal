#!/bin/zsh
# Sync gateway/ + infra/ to the VM and (re)start the compose stack.
# Usage: infra/deploy.sh <vm-ip-or-hostname>
set -euo pipefail
host=${1:?usage: infra/deploy.sh <host>}
root=${0:A:h:h}
remote=finops@$host
dir=/opt/finops

rsync -az --delete --exclude .venv --exclude __pycache__ --exclude .pytest_cache \
  "$root/gateway/" "$remote:$dir/gateway/"
rsync -az "$root/infra/compose.yaml" "$remote:$dir/infra/"

# First deploy: generate secrets on the VM (they never leave it).
ssh "$remote" "cd $dir && if [ ! -f .env ]; then umask 077; {
  echo POSTGRES_PASSWORD=\$(openssl rand -hex 24)
  echo GATEWAY_TOKEN=\$(openssl rand -hex 32)
  echo FRED_API_KEY=
  echo EDGAR_CONTACT=
} > .env; echo '  generated .env'; fi"

ssh "$remote" "cd $dir/infra && docker-compose --env-file ../.env up -d --build --remove-orphans && sleep 5 && docker-compose --env-file ../.env ps"

# TLS on the tailnet: tailscaled terminates HTTPS with its *.ts.net certificate (idempotent).
ssh "$remote" "sudo tailscale serve --bg --https=443 http://127.0.0.1:8765 >/dev/null && tailscale serve status"

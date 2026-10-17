# infra — finops-backend VM

Phase 0 of [docs/BACKEND_PLAN.md](../docs/BACKEND_PLAN.md): a dedicated Debian 13 VM on Proxmox,
provisioned with cloud-init, running the gateway, Postgres (TimescaleDB) and Redis in Docker Compose.

| Item | Value |
|---|---|
| VM | `110 finops-backend` on node `proxmox`, 2 vCPU, 3 GiB (balloon min 1.5 GiB), 32 G on `vmdata` |
| Access | `ssh finops@<ip>` (keys from your SSH agent + `~/.ssh/id_*.pub`), then Tailscale |
| API | `wss://finops-backend.<tailnet>.ts.net/ws` — TLS by `tailscale serve`, tailnet only, per-device auth |
| Firewall | nftables: SSH from the LAN, everything from `tailscale0`, all else dropped |
| Stack | `/opt/finops/infra/compose.yaml`, secrets in `/opt/finops/.env` (0600, generated on the VM) |
| Backups | Proxmox job: daily 03:15 snapshot to `local`, keep 7 |

## Rebuild from scratch
```bash
PVE_TOKEN="op://Private/<proxmox item>/credential" op run -- python3 infra/create_vm.py
infra/find_ip.sh bc:24:11:03:09:b2            # until the guest agent reports the IP
ssh finops@<ip> 'sudo bash -s' < infra/bootstrap.sh
ssh finops@<ip> sudo tailscale up --hostname=finops-backend   # open the printed URL
infra/deploy.sh <ip>
```
Every script is idempotent: rerun it after a change.

## Operate
```bash
infra/deploy.sh <ip>                                            # ship gateway/ + compose, rebuild, restart
ssh finops@<ip> 'cd /opt/finops/infra && docker-compose --env-file ../.env ps'
ssh finops@<ip> 'cd /opt/finops/infra && docker-compose --env-file ../.env logs -f api'
ssh -L 8765:127.0.0.1:8765 finops@<ip>                          # reach the API from the Mac (phase 0)
```
## Devices
```bash
ssh finops@<ip> docker exec finops-api-1 finops-admin pair      # 6-digit code, 5 min, 5 attempts
ssh finops@<ip> docker exec finops-api-1 finops-admin devices
ssh finops@<ip> docker exec finops-api-1 finops-admin revoke <device-id>
```
Enter the code on the Mac (Settings → Backend) or the iPad (connection screen → finops backend).
The device keeps a token in its Keychain; the backend stores only its SHA-256.

Provider settings go in `/opt/finops/.env` (`FRED_API_KEY`, `EDGAR_CONTACT`), then `infra/deploy.sh`.

# Backend plan — finops-terminal

**Status:** Proposal, 2026-10-17
**Goal:** replace "data comes from the Python sidecar on the Mac" with a real, always-on
backend running in a dedicated Proxmox VM. The Mac and iPad apps (and later others) connect
to it from anywhere, with their data synced and alerts evaluated 24/7.

---

## 1. What changes for the user

| Today | With the backend |
|---|---|
| The iPad only works next to a Mac that's switched on | The iPad works anywhere, on its own |
| Watchlists, portfolio and alerts are stored separately on each device | Synced across Mac and iPad |
| Alerts only fire while the app is open | Alerts are checked on the server 24/7 and pushed to the Mac and iPad (APNs) |
| Every device calls Yahoo/EDGAR/FRED itself | One shared cache, so fewer calls and less rate limiting |
| The keypad needs the same Wi-Fi as the Mac | The keypad is relayed by the backend, so it works from anywhere |
| The FRED key is stored on each Mac | Keys live only on the server |

## 2. Infrastructure — dedicated VM through cloud-init

### 2.1 Host capacity (read via the API on 2026-10-17)
- Node `proxmox`: Ryzen 7 3700X (16 threads), **RAM 12.3 / 15.5 GiB used**, PVE 9.2.2.
- Storage: `vmdata` 34/115 G, `local-lvm` 87/137 G, `local` 13/66 G.
- Existing guests: 100 plex (4 G), 101 quickbox (4 G), 102 supabase (4 G), 104/105 LXC (2 G
  each, ~0.3 G used), 106/107 stopped.

**RAM is the constraint.** A 3 GiB VM brings the node to about 98%. Options, to decide (§8):
use ballooning (min 1.5 G / max 3 G), reclaim RAM from `supabase` (102) if it's idle,
or add RAM to the host.

### 2.2 The VM
| Setting | Value |
|---|---|
| VMID / name | `110` / `finops-backend` |
| Image | Debian 13 "trixie" genericcloud amd64 (qcow2), imported with `import-from` |
| CPU / RAM | 2 vCPU (`host`), 3 GiB with balloon min 1.5 GiB |
| Disk | 32 G on `vmdata` (virtio-scsi, discard, SSD emulation) |
| Network | `vmbr0`, fixed IP (e.g. `192.168.1.70/24`) or a DHCP reservation |
| Agent | `qemu-guest-agent` enabled (IP reporting, clean shutdown, consistent backups) |
| Cloud-init | user `finops`, your SSH public key, no password, `ipconfig0` |
| Backup | daily `vzdump` snapshot to `vmdata`, keep 7, plus a nightly Postgres `pg_dump` |

### 2.3 Creation, fully through the Proxmox API/MCP (no SSH to the host)
1. `POST /nodes/proxmox/storage/local/download-url`: download the Debian cloud image into
   `local` with content type `import` (check the SHA-512 against Debian's published checksum).
2. `POST /nodes/proxmox/qemu`: create the VM with
   `scsi0=vmdata:0,import-from=local:import/debian-13-genericcloud-amd64.qcow2`,
   `ide2=vmdata:cloudinit`, `agent=1`, `ciuser`, `sshkeys`, `ipconfig0`, `boot=order=scsi0`,
   `serial0=socket` and `vga=serial0`. Resize the disk to 32 G.
3. Start it, wait for the guest agent, read its IP.

Cloud-init's built-in options (user, key, network) are enough to get a VM we can reach.
Custom cloud-init user-data (a "snippet") requires writing a file on the host, which the API
can't do. So software setup is done by an **idempotent bootstrap script in the repo**
(`infra/bootstrap.sh`), run over SSH. It handles packages, Docker, the firewall, Tailscale
and the service user, and rebuilds the VM identically every time.

### 2.4 Remote access
- **Recommended: Tailscale** on the VM. The backend is only reachable on your tailnet, with
  nothing exposed to the internet. Install Tailscale on the Mac and iPad. TLS comes through
  MagicDNS + `tailscale cert`.
- Alternative: **Cloudflare Tunnel + Access**, for a public HTTPS hostname without a VPN on
  the devices. It needs a domain on Cloudflare, and the iPad has to get through Access (service tokens).
- In both cases: `nftables` firewall that only allows SSH from the LAN or tailnet and the
  API from the tailnet. No ports forwarded on the router.

## 3. Software architecture (Docker Compose on the VM)

```
 Mac app ─┐                       ┌──────────────── finops-backend (VM 110) ────────────────┐
 iPad app ┼── WSS/HTTPS ─────────►│ caddy (TLS) ─► api (FastAPI: REST + WebSocket)          │
 (keypad) ┘   over Tailscale      │                 ├─ auth (devices, tokens)               │
                                  │                 ├─ data protocol (refdata, history, …)  │
                                  │                 ├─ user data (watchlists, portfolio…)   │
                                  │                 └─ device relay (keypad ⇄ Mac)          │
                                  │ worker ─ alerts 24/7, cache warming, EDGAR/FRED refresh │
                                  │   └─► APNs (push to Mac / iPad)                         │
                                  │ postgres 17 + timescaledb ─ users, devices, data, series│
                                  │ redis ─ quote pub/sub, rate limits, short cache         │
                                  └──────────────────────► Yahoo · SEC EDGAR · FRED ────────┘
```

| Service | Role | Notes |
|---|---|---|
| `api` | The current gateway, turned into a multi-client server | Same WebSocket protocol, so clients barely change. Adds REST for user data. |
| `worker` | Background jobs (arq or APScheduler) | Alerts every 30–60 s, quote cache, EDGAR at night, FRED by release date |
| `postgres` | System of record | Timescale for series (`history`, `econ`) and the persistent cache |
| `redis` | Hot cache and fan-out | One upstream subscription per symbol, shared by all clients |
| `caddy` | TLS + reverse proxy | Tailscale certificate, or behind cloudflared |

**Why not reuse the `supabase` VM (102)?** That's possible for Postgres and Auth, but it
couples finops to a VM you use for other things, and it's already at 3.6/4 G. The dedicated
VM keeps everything self-contained and rebuildable. Supabase stays an option for authentication if you
ever want multiple users.

### 3.1 Data model (Postgres)
- `users` (just you for now, but the column is there from the start).
- `devices` (id, name, platform, token hash, APNs token, last seen). This reuses the pairing
  already built for the iPad.
- `watchlists`, `watchlist_items`, `positions`, `alerts` (with `triggered_at`), `workspaces`
  (layout and panels as JSON).
- `series_cache` (hypertable: symbol, field, interval, ts, value), `doc_cache` (EDGAR/FRED
  documents with TTL).

### 3.2 Authentication
- Pairing by code, like today, but against the backend. The first device is "bootstrapped" with
  a one-time code printed in the API logs. Each device gets a revocable token (hash stored server-side).
- Tokens in the device Keychain. The token goes on the WebSocket hello and as a Bearer on REST.
- Defense in depth: tailnet + token. Rate limiting per device in Redis.

### 3.3 Sync
- REST `GET/PUT` per collection with `updated_at` (last-write-wins, enough for a single user).
- Realtime push of changes over the existing WebSocket (`sync.changed`), so the Mac and iPad
  update instantly.
- Local cache on each device: the apps keep working offline using the last state.

### 3.4 Server-side alerts and push
- The worker evaluates active alerts against the Redis cache. On a trigger it writes `triggered_at`,
  sends a WebSocket message, and sends **APNs** pushes to registered devices.
- APNs: an `.p8` key from your Apple Developer team (52S288U9A6), stored as a secret on the VM.
  The Mac and iPad request push permission and send their APNs token to the backend.

## 4. Client changes
- **Mac:** a new "Backend" setting (URL plus pairing). The local sidecar stays as a fallback
  ("local mode") when the backend is unreachable.
- **iPad:** connects directly to the backend. LAN pairing with the Mac is no longer needed.
- **Keypad:** the backend relays `remote.*` between the user's devices, so the keypad works
  from anywhere. Direct LAN mode can stay as a fallback.
- **Stores:** `UserDefaults` → a sync client (local cache + API). One-time migration of
  existing data on first connection.

## 5. Delivery and operations
- Repo: `backend/` (the current `gateway/`, renamed and extended), `infra/` (cloud-init, bootstrap,
  compose, Caddyfile), and documented migrations (Alembic).
- CI (GitHub Actions): tests, then a `backend` image pushed to GHCR. Deploy: `docker compose pull && up -d`
  over SSH through Tailscale (GitHub Action `tailscale/github-action`), or manual at first.
- Secrets: `.env` on the VM (0600), never in git. FRED key and EDGAR contact on the server.
- Observability: `/healthz`, structured logs, Uptime Kuma (optional), and alerts if Yahoo stops
  responding (already flagged as `stale` in the protocol).
- Backups: vzdump of the VM plus `pg_dump` (7 days), with a restore test in phase 1.

## 6. Phases

| Phase | Content | Done when |
|---|---|---|
| **0 · Infra** ✅ | `infra/` (bootstrap, compose), VM 110 via cloud-init, Tailscale, firewall, backups | `ssh finops@finops-backend` works and `docker compose ps` is healthy |
| **1 · Gateway as a server** ✅ | Containerized gateway, Postgres/Redis, device auth, Mac/iPad pointed at the backend (Mac fallback kept) | The iPad shows a chart over 4G with no Mac running |
| **2 · Sync** | API for watchlists/portfolio/alerts/workspaces, data migration, realtime push | A watchlist edited on the iPad appears on the Mac within 1 s |
| **3 · Server-side alerts** | Alerts worker, APNs, triggered history | An alert arrives on the iPad with both apps closed |
| **4 · Cache and history** | Timescale for series, Redis fan-out, cache warming | Repeated CHART / FIN in < 100 ms, Yahoo calls down by more than 80% |
| **5 · Remote keypad** | Relay of `remote.*` through the backend | The keypad drives the Mac from outside the home network |

## 7. Risks
- **Host RAM** (see §2.1). This is the main blocker.
- **Yahoo** may throttle. That's mitigated: the home IP is better than a datacenter, and caching
  plus fan-out reduce the number of calls.
- **Single point of failure:** if the VM is down, the Mac keeps working in local mode, and the iPad
  only has its local cache.
- **Personal use** of Yahoo data: the backend stays private (tailnet), with no public sharing.

## 8. Decisions to make before phase 0
1. **RAM:** ballooning only, reclaim from `supabase` (102), or add RAM?
2. **Access:** Tailscale (recommended) or Cloudflare Tunnel?
3. **IP:** fixed IP (which one? gateway `192.168.1.1`?) or a DHCP reservation?
4. **SSH key:** which public key to put in cloud-init (`~/.ssh/id_ed25519.pub`?)
5. **APNs:** OK to create an APNs `.p8` key on your Apple Developer team?

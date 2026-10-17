#!/usr/bin/env python3
"""Create (or reuse) the finops-backend VM on Proxmox with a Debian cloud image + cloud-init.

Idempotent: every step checks current state first. Talks only to the Proxmox API.

Usage (token from 1Password, never printed):
    PVE_TOKEN="op://Private/<item>/credential" op run -- python3 infra/create_vm.py

Environment:
    PVE_TOKEN   API token secret for PVE_TOKEN_ID (required)
    PVE_TOKEN_ID  default root@pam!claude
    PVE_HOST    default https://192.168.1.60:8006
    PVE_CA      default ~/.config/proxmox-mcp/pve-root-ca.pem
    SSH_PUBKEY  default ~/.ssh/id_rsa.pub
"""

from __future__ import annotations

import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

NODE = "proxmox"
VMID = 110
NAME = "finops-backend"
IMAGE_URL = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMAGE_SHA512 = (
    "ec584ccabfef7120b4c4f7482adf0e615894d9292cedec446b64194b951ebe5d"
    "d97c336b5dcbae458333764b0edd516334506017f33c4f2020ef8d38b569ffe3"
)
IMAGE_FILE = "debian-13-genericcloud-amd64.qcow2"
IMPORT_STORAGE = "local"
DISK_STORAGE = "vmdata"
DISK_SIZE = "32G"
CORES = 2
MEMORY_MB = 3072
BALLOON_MB = 1536
BRIDGE = "vmbr0"
CI_USER = "finops"
BACKUP_STORAGE = "local"


class PVE:
    def __init__(self) -> None:
        self.base = os.environ.get("PVE_HOST", "https://192.168.1.60:8006").rstrip("/") + "/api2/json"
        token_id = os.environ.get("PVE_TOKEN_ID", "root@pam!claude")
        secret = os.environ["PVE_TOKEN"]
        self.auth = f"PVEAPIToken={token_id}={secret}"
        ca = os.path.expanduser(os.environ.get("PVE_CA", "~/.config/proxmox-mcp/pve-root-ca.pem"))
        self.ctx = ssl.create_default_context(cafile=ca)

    def call(self, method: str, path: str, params: dict | None = None):
        data = None
        url = self.base + path
        if params and method == "GET":
            url += "?" + urllib.parse.urlencode(params)
        elif params:
            data = urllib.parse.urlencode(params).encode()
        req = urllib.request.Request(url, data=data, method=method, headers={"Authorization": self.auth})
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=60) as r:
                return json.loads(r.read() or b"{}").get("data")
        except urllib.error.HTTPError as e:
            raise SystemExit(f"{method} {path} -> HTTP {e.code}: {e.read()[:400].decode(errors='replace')}") from None

    def wait_task(self, upid: str, what: str, timeout: int = 1800) -> None:
        start = time.time()
        path = f"/nodes/{NODE}/tasks/{urllib.parse.quote(upid, safe='')}/status"
        while time.time() - start < timeout:
            st = self.call("GET", path)
            if st.get("status") == "stopped":
                if st.get("exitstatus") != "OK":
                    raise SystemExit(f"{what} failed: {st.get('exitstatus')}")
                print(f"  ✓ {what}")
                return
            time.sleep(3)
        raise SystemExit(f"{what} timed out")


def authorized_keys() -> str:
    """SSH_PUBKEY file if set; otherwise the keys held by the SSH agent (e.g. 1Password) plus ~/.ssh/id_*.pub."""
    if path := os.environ.get("SSH_PUBKEY"):
        return Path(os.path.expanduser(path)).read_text().strip()
    import subprocess
    keys = subprocess.run(["ssh-add", "-L"], capture_output=True, text=True).stdout.splitlines()
    keys += [p.read_text().strip() for p in sorted(Path.home().glob(".ssh/id_*.pub"))]
    keys = [k for k in dict.fromkeys(k.strip() for k in keys) if k.startswith(("ssh-", "ecdsa-"))]
    if not keys:
        raise SystemExit("no SSH public key found (set SSH_PUBKEY)")
    return "\n".join(keys)


def step(msg: str) -> None:
    print(f"→ {msg}", flush=True)


def main() -> None:
    pve = PVE()
    pubkey = authorized_keys()

    # 1. Cloud image in the import store.
    step(f"cloud image {IMAGE_FILE}")
    content = pve.call("GET", f"/nodes/{NODE}/storage/{IMPORT_STORAGE}/content", {"content": "import"}) or []
    if any(c["volid"].endswith(f"import/{IMAGE_FILE}") for c in content):
        print("  ✓ already present")
    else:
        upid = pve.call("POST", f"/nodes/{NODE}/storage/{IMPORT_STORAGE}/download-url", {
            "url": IMAGE_URL, "content": "import", "filename": IMAGE_FILE,
            "checksum": IMAGE_SHA512, "checksum-algorithm": "sha512",
        })
        pve.wait_task(upid, "downloaded and checksum verified")

    # 2. VM.
    step(f"VM {VMID} ({NAME})")
    vms = {v["vmid"]: v for v in pve.call("GET", f"/nodes/{NODE}/qemu")}
    if VMID in vms:
        if vms[VMID].get("name") != NAME:
            raise SystemExit(f"VMID {VMID} is taken by {vms[VMID].get('name')!r}; refusing to touch it")
        print("  ✓ already exists")
        current = urllib.parse.unquote(pve.call("GET", f"/nodes/{NODE}/qemu/{VMID}/config").get("sshkeys", ""))
        if current.strip() != pubkey.strip():
            pve.call("PUT", f"/nodes/{NODE}/qemu/{VMID}/config", {"sshkeys": urllib.parse.quote(pubkey, safe="")})
            print("  ✓ SSH keys updated")
    else:
        upid = pve.call("POST", f"/nodes/{NODE}/qemu", {
            "vmid": VMID, "name": NAME, "description": "finops-terminal backend (managed by infra/create_vm.py)",
            "ostype": "l26", "machine": "q35", "bios": "seabios", "cpu": "host",
            "cores": CORES, "memory": MEMORY_MB, "balloon": BALLOON_MB,
            "scsihw": "virtio-scsi-single",
            "scsi0": f"{DISK_STORAGE}:0,import-from={IMPORT_STORAGE}:import/{IMAGE_FILE},discard=on,ssd=1,iothread=1",
            "ide2": f"{DISK_STORAGE}:cloudinit",
            "boot": "order=scsi0", "serial0": "socket", "vga": "serial0",
            "net0": f"virtio,bridge={BRIDGE},firewall=0",
            "agent": "enabled=1,fstrim_cloned_disks=1",
            "ciuser": CI_USER, "sshkeys": urllib.parse.quote(pubkey, safe=""),
            "ipconfig0": "ip=dhcp", "ciupgrade": 1,
            "onboot": 1, "tags": "finops",
        })
        pve.wait_task(upid, "created")
        upid = pve.call("PUT", f"/nodes/{NODE}/qemu/{VMID}/resize", {"disk": "scsi0", "size": DISK_SIZE})
        if isinstance(upid, str):
            pve.wait_task(upid, f"disk resized to {DISK_SIZE}")

    # Apply pending cloud-init values to the cloud-init drive (otherwise the first boot
    # can come up without the user/SSH key).
    if pve.call("GET", f"/nodes/{NODE}/qemu/{VMID}/cloudinit"):
        pve.call("PUT", f"/nodes/{NODE}/qemu/{VMID}/cloudinit")
        print("  ✓ cloud-init drive regenerated")
        if pve.call("GET", f"/nodes/{NODE}/qemu/{VMID}/status/current").get("status") == "running":
            pve.wait_task(pve.call("POST", f"/nodes/{NODE}/qemu/{VMID}/status/reboot"), "rebooted to apply cloud-init")

    # 3. Start and wait for the guest agent.
    step("start + guest agent")
    status = pve.call("GET", f"/nodes/{NODE}/qemu/{VMID}/status/current")
    if status.get("status") != "running":
        pve.wait_task(pve.call("POST", f"/nodes/{NODE}/qemu/{VMID}/status/start"), "started")
    ip = None
    for _ in range(10):
        try:
            ifaces = pve.call("GET", f"/nodes/{NODE}/qemu/{VMID}/agent/network-get-interfaces")["result"]
            ips = [a["ip-address"] for i in ifaces if i["name"] != "lo"
                   for a in i.get("ip-addresses", []) if a["ip-address-type"] == "ipv4"]
            if ips:
                ip = ips[0]
                break
        except SystemExit:
            pass  # agent not up yet (first boot installs it via cloud-init upgrade)
        time.sleep(6)
    if ip:
        print(f"  ✓ IP {ip}")
    else:
        # The genericcloud image has no guest agent until bootstrap installs it: find us by MAC.
        net0 = pve.call("GET", f"/nodes/{NODE}/qemu/{VMID}/config")["net0"]
        mac = next(p.split("=")[1] for p in net0.split(",") if p.lower().startswith("virtio="))
        print(f"  ! no guest agent yet; MAC {mac.lower()} (see infra/find_ip.sh)")

    # 4. Daily backup job.
    step("backup job")
    jobs = pve.call("GET", "/cluster/backup") or []
    if any(str(VMID) in str(j.get("vmid", "")).split(",") for j in jobs):
        print("  ✓ already scheduled")
    else:
        pve.call("POST", "/cluster/backup", {
            "vmid": VMID, "storage": BACKUP_STORAGE, "schedule": "03:15", "mode": "snapshot",
            "compress": "zstd", "prune-backups": "keep-last=7", "enabled": 1,
            "comment": "finops-backend daily",
        })
        print("  ✓ daily 03:15, keep 7")

    if ip:
        print(f"\nNext: ssh {CI_USER}@{ip}   then   infra/deploy.sh {ip}")


if __name__ == "__main__":
    try:
        main()
    except KeyError as e:
        sys.exit(f"missing environment variable {e}")

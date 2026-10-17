#!/bin/zsh
# Find a host on the LAN by MAC address: ping-sweep the /24, then read the ARP table.
# Usage: infra/find_ip.sh bc:24:11:aa:bb:cc [192.168.1]
set -euo pipefail
mac=${1:l}
net=${2:-192.168.1}
for i in {1..254}; do ping -c1 -W 300 "$net.$i" >/dev/null 2>&1 & done; wait
# macOS arp prints octets without leading zeros: normalise both sides.
norm() { python3 -c 'import sys; print(":".join("%x" % int(x, 16) for x in sys.argv[1].split(":")))' "$1"; }
want=$(norm "$mac")
arp -an | while read -r _ ip _ m _; do
  [[ "$m" == *:* ]] || continue
  [[ "$(norm "$m")" == "$want" ]] && echo "${ip//[()]/}"
done

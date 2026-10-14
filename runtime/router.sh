#!/usr/bin/env bash
# Inter-subnet router for the lab. Attached to both lab networks at .254.
# Forwarding is enabled via compose 'sysctls'. Optional WAN emulation via netem.
set -Eeuo pipefail
log() { printf '[router] %s\n' "$*"; }

# Identify interfaces by their IPv4 address (Docker interface order is not guaranteed).
ifname_for() { ip -o -4 addr show | awk -v ip="$1" '$4 ~ "^"ip"/" {print $2; exit}'; }
IF_A=$(ifname_for "${LAB_NET_A_ROUTER:?}")
IF_B=$(ifname_for "${LAB_NET_B_ROUTER:?}")
log "subnet A on ${IF_A:-?}, subnet B on ${IF_B:-?}"
[[ -n "$IF_A" && -n "$IF_B" ]] || { log "router interfaces not found"; ip -o -4 addr show; exit 1; }

if [[ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]]; then
  log "ip_forward is off; compose must set sysctls net.ipv4.ip_forward=1"; exit 1
fi
# Never send ICMP redirects (VMs would learn the host as a shortcut and bypass the router).
# (set via compose sysctls; /proc/sys is read-only inside the container)

if [[ "${LAB_INTERNET:-0}" != "1" ]]; then
  ip route del default 2>/dev/null || true
  log "internet access disabled (no default route)"
fi

if [[ -n "${LAB_WAN_DELAY:-}" ]]; then
  # shellcheck disable=SC2086  # intentional word splitting of netem args
  tc qdisc replace dev "$IF_A" root netem delay ${LAB_WAN_DELAY}
  # shellcheck disable=SC2086
  tc qdisc replace dev "$IF_B" root netem delay ${LAB_WAN_DELAY}
  log "WAN emulation: netem delay ${LAB_WAN_DELAY} on both legs"
fi

log "ready"
trap 'exit 0' TERM INT
sleep infinity & wait $!

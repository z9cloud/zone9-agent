#!/bin/sh
# zone9-guest-net — routing policy for dual-homed guests.
#
# The problem it solves: Proxmox cloud-init can only express "address + gateway"
# per interface — it cannot write static routes. A VM with both a public interface
# and a private one therefore ends up with TWO default routes. Traffic arrives on
# the public interface, but replies leave through whichever default the kernel
# picks; when that is the private one they are dropped, because a private subnet
# has no path to the internet.
#
# The symptom is distinctive: 50-70% packet loss on ping, and TCP connections that
# never complete. A clean 0% means the routing is right.
#
# What this script does at every boot:
#
#   - classify each default route: RFC1918 gateway -> "private", otherwise "public"
#   - if both exist: drop the private default route and replace it with explicit
#     RFC1918 destinations (10/8, 172.16/12, 192.168/16) via the private gateway,
#     leaving the default route on the public leg. The VM then sources traffic
#     from its own public address, and still reaches the other subnets of its
#     private network.
#   - if there is only a private leg: do nothing (egress goes through the anycast
#     gateway with source NAT, which is correct).
#
# Large providers solve this with DHCP classless static routes (option 121).
# Proxmox SDN has no such path today, so the policy is baked into the image.
# Idempotent: safe to run on every boot.
set -eu

is_private() {
  case "$1" in
    10.*) return 0 ;;
    192.168.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
  esac
  return 1
}

PRIV_GW=""; PRIV_DEV=""; PUB_DEV=""
# Lines look like: "default via 10.192.0.1 dev eth0 proto static"
ip -4 route show default | while read -r _ _ gw _ dev _; do
  echo "$gw $dev"
done > /run/zone9-guest-net.defaults

while read -r gw dev; do
  [ -n "$gw" ] || continue
  if is_private "$gw"; then PRIV_GW="$gw"; PRIV_DEV="$dev"; else PUB_DEV="$dev"; fi
done < /run/zone9-guest-net.defaults

# Single private leg whose default is a network gateway VM (not the subnet's
# anycast .1): the VPC's other subnets must still be reached through the anycast,
# because the gateway does not route between legs. Per the address plan (ADR-037)
# a VPC is the enclosing /20 of the interface's address; the anycast gateway is the
# first host of the interface's own subnet. The route is added explicitly here since
# cloud-init cannot express it.
if [ -n "$PRIV_GW" ] && [ -z "$PUB_DEV" ]; then
  addr="$(ip -4 -o addr show dev "$PRIV_DEV" 2>/dev/null | awk '{print $4; exit}')"   # 10.192.16.20/24
  ip_only="${addr%/*}"; bits="${addr#*/}"
  if [ -n "$ip_only" ] && [ "$bits" -ge 20 ] 2>/dev/null; then
    o1="${ip_only%%.*}"; rest="${ip_only#*.}"; o2="${rest%%.*}"; rest="${rest#*.}"; o3="${rest%%.*}"
    anycast="$o1.$o2.$o3.1"
    if [ "$PRIV_GW" != "$anycast" ]; then
      vpc="$o1.$o2.$(( o3 & 240 )).0/20"
      ip -4 route replace "$vpc" via "$anycast" dev "$PRIV_DEV" metric 50
      echo "zone9-guest-net: default via gateway $PRIV_GW; VPC $vpc via anycast $anycast"
      exit 0
    fi
  fi
fi

if [ -z "$PRIV_GW" ] || [ -z "$PUB_DEV" ]; then
  echo "zone9-guest-net: single-homed or no public leg; routes unchanged"
  exit 0
fi

# Drop the private default route; hand RFC1918 to the private gateway instead.
ip -4 route del default via "$PRIV_GW" dev "$PRIV_DEV" 2>/dev/null || true
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
  ip -4 route replace "$net" via "$PRIV_GW" dev "$PRIV_DEV" metric 100
done
echo "zone9-guest-net: public=$PUB_DEV (default), private=$PRIV_DEV via $PRIV_GW (RFC1918)"

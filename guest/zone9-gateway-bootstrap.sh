#!/bin/sh
# zone9-gateway-bootstrap — the network gateway appliance ("Ağ Geçidi").
#
# One gateway VM per customer, attached to the subnets it serves, carrying one of
# the customer's public IPs. It does two things and nothing else:
#
#   1. EGRESS  — every boot: SNAT the private legs out of the public leg so the
#                customer's machines reach the internet from the CUSTOMER's IP.
#   2. ZERO TRUST — on request: join the customer's tailnet as a subnet router.
#
# It deliberately does NOT forward inbound traffic to private machines and does
# NOT route between private legs: a gateway with legs in two VPCs would otherwise
# become an accidental peering between them. FORWARD policy is DROP; only the
# flows listed below pass.
#
# How a locked VM receives a request when the hypervisor offers no channel:
# the panel writes a single-use token into SMBIOS (`qm set --smbios1 serial=z9:...`),
# this script reads /sys/class/dmi/id/product_serial on boot and calls the panel
# OUTBOUND over HTTPS. The payload is handed over once and deleted server-side.
# Enabling or disabling Zero Trust therefore means: new token, reboot (~30s of
# egress interruption — accepted).
#
# Runs on every boot (cloud-init per-boot hook). Egress setup is idempotent; the
# token part does nothing unless a z9: serial is present and its marker is absent.
set -eu

API_URL="$(cat /etc/zone9/api-url 2>/dev/null || echo https://zone9.cloud/api/v1)"
API_URL="${API_URL%/}"
STATE="${ZONE9_STATE_DIR:-/var/lib/zone9}"
SERIAL_FILE="${ZONE9_SERIAL_FILE:-/sys/class/dmi/id/product_serial}"
# No login on this VM (no sshd, no getty): the serial console is the only place an
# operator can read what happened. Log to the journal AND /dev/console.
log() { logger -t zone9-gateway "$*"; printf 'zone9-gateway: %s\n' "$*" > /dev/console 2>/dev/null || true; }

mkdir -p "$STATE"

# Same RFC1918 classification as zone9-guest-net; an empty next hop (on-link
# default) counts as public.
is_private() {
  case "$1" in
    10.*) return 0 ;;
    192.168.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# 1. Egress — every boot
# ---------------------------------------------------------------------------

# The dual-leg route policy (default route on the public leg) is applied by
# zone9-guest-net. Run it first so the public interface is known regardless of the
# order in which cloud-init executes per-boot hooks.
[ -x /usr/local/sbin/zone9-guest-net ] && /usr/local/sbin/zone9-guest-net || true

# The public leg is the default route whose next hop is NOT RFC1918. "The first
# default route" was not good enough: the panel can leave a default route on a
# private leg too, and then MASQUERADE is written on the wrong interface and every
# customer machine behind the gateway silently loses egress (measured in production
# on 2026-09-07, after a fourth leg was attached). Fall back to the first default
# route when no public one exists, so a single-homed test VM still configures.
ip -4 route show default 2>/dev/null | awk '{gw="";dev="";
  for (i=1;i<=NF;i++) { if ($i=="via") gw=$(i+1); else if ($i=="dev") dev=$(i+1) }
  if (dev != "") print gw" "dev}' > /run/zone9-gateway.defaults
pub_if=""; first_if=""
while read -r gw dev; do
  [ -n "$dev" ] || continue
  [ -n "$first_if" ] || first_if="$dev"
  is_private "$gw" && continue
  pub_if="$dev"; break
done < /run/zone9-gateway.defaults
[ -n "$pub_if" ] || pub_if="$first_if"
if [ -z "$pub_if" ]; then
  log "no default route yet; egress not configured (will retry next boot)"
else
  printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' > /etc/sysctl.d/99-zone9-gateway.conf
  sysctl -q -p /etc/sysctl.d/99-zone9-gateway.conf

  # Private legs: every interface that is not the public one, not loopback, not tailscale.
  priv_ifs="$(ip -4 -o addr show 2>/dev/null | awk '{print $2}' | sort -u \
              | grep -v -e '^lo$' -e "^${pub_if}\$" -e '^tailscale' || true)"

  # Rules are checked (-C) before being added so a re-run does not duplicate them.
  rule() { iptables -C "$@" 2>/dev/null || iptables -A "$@"; }
  natrule() { iptables -t nat -C "$@" 2>/dev/null || iptables -t nat -A "$@"; }

  # Nothing is forwarded unless a rule below allows it. This is what blocks
  # private↔private across legs (no accidental VPC peering) and any inbound
  # forwarding from the public side.
  iptables -P FORWARD DROP
  rule FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
  for i in $priv_ifs; do
    rule FORWARD -i "$i" -o "$pub_if" -j ACCEPT          # private → internet
    rule FORWARD -i tailscale0 -o "$i" -j ACCEPT         # tailnet → private (Zero Trust)
  done
  natrule POSTROUTING -o "$pub_if" -j MASQUERADE         # egress leaves with the public IP
  log "egress ready: public=$pub_if private=$(echo $priv_ifs | tr ' ' ',')"
fi

# ---------------------------------------------------------------------------
# 2. Token — only when the panel asked for something
# ---------------------------------------------------------------------------

serial="$(cat "$SERIAL_FILE" 2>/dev/null || true)"
case "$serial" in
  z9:*) token="${serial#z9:}" ;;
  *) exit 0 ;;
esac

marker="$STATE/gateway.$(printf '%s' "$token" | cksum | cut -d' ' -f1).done"
[ -f "$marker" ] && exit 0

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
i=0; code=000
while [ "$i" -lt 30 ]; do
  code="$(curl -sS --max-time 15 -o "$tmp" -w '%{http_code}' \
          -H "Authorization: Bearer $token" "$API_URL/bootstrap?format=env" || echo 000)"
  case "$code" in
    200) break ;;
    401|410) log "panel refused the bootstrap token (HTTP $code): $(head -c 200 "$tmp")"; exit 1 ;;
  esac
  i=$((i+1)); sleep 10
done
[ "$code" = 200 ] || { log "panel unreachable after retries (last HTTP $code)"; exit 1; }

Z9_KIND=""; Z9_LOGIN_SERVER=""; Z9_AUTH_KEY=""; Z9_ROUTES=""; Z9_HOSTNAME=""
while IFS='=' read -r k v; do
  case "$k" in
    Z9_KIND|Z9_LOGIN_SERVER|Z9_AUTH_KEY|Z9_ROUTES|Z9_HOSTNAME) eval "$k=\$v" ;;
  esac
done < "$tmp"

start_service() {
  if command -v systemctl >/dev/null 2>&1; then systemctl enable --now "$1"
  else rc-update add "$1" default >/dev/null 2>&1 || true; rc-service "$1" start; fi
}

case "$Z9_KIND" in
  tailscale-gateway)
    [ -n "$Z9_LOGIN_SERVER" ] && [ -n "$Z9_AUTH_KEY" ] && [ -n "$Z9_ROUTES" ] \
      || { log "incomplete tailscale-gateway payload"; exit 1; }
    start_service tailscaled
    # --accept-dns=false: a router, not a workstation; its resolver stays the
    # platform's. --reset: exactly these flags, no leftovers from a previous up.
    tailscale up --reset \
      --login-server "$Z9_LOGIN_SERVER" \
      --authkey "$Z9_AUTH_KEY" \
      --advertise-routes "$Z9_ROUTES" \
      --hostname "${Z9_HOSTNAME:-zone9-gateway}" \
      --accept-dns=false
    log "zero trust up: routes=$Z9_ROUTES login=$Z9_LOGIN_SERVER"
    ;;
  tailscale-down)
    # logout, not just down: the node key is invalidated, so re-enabling needs a
    # fresh auth key — which is exactly what the enable flow provides.
    tailscale logout 2>/dev/null || true
    if command -v systemctl >/dev/null 2>&1; then systemctl disable --now tailscaled || true; fi
    log "zero trust down"
    ;;
  *) log "refusing bootstrap kind '$Z9_KIND': this image is a network gateway"; exit 1 ;;
esac

printf 'kind=%s\nat=%s\n' "$Z9_KIND" "$(date -u +%FT%TZ)" > "$marker"

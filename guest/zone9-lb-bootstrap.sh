#!/bin/sh
# zone9-lb-bootstrap — the load balancer appliance ("Yük dengeleyici").
#
# One VM per load balancer, carrying one of the customer's public IPs, with a leg
# in the customer's private network. It runs haproxy; the configuration is NOT
# written by hand and is NOT pushed by the panel — the zone9-lb daemon pulls it
# with the VM's own identity and reloads haproxy without dropping connections.
#
# This script runs on every boot (cloud-init per-boot hook) and does two things:
#
#   1. Apply the dual-leg route policy (default route on the public leg).
#   2. Enroll, once: read the single-use bootstrap token from SMBIOS
#      (/sys/class/dmi/id/product_serial, "z9:<token>"), exchange it OUTBOUND over
#      HTTPS for the VM's long-lived identity, write it to /etc/zone9/lb.env and
#      start the daemon. The panel deletes the payload once it is handed over.
#      A new token (identity reset from the panel) is detected by its marker being
#      absent and replaces the stored identity.
#
# No login on this VM (no sshd, no getty): the serial console is the only place an
# operator can read what happened, so everything is logged there too.
set -eu

API_URL="$(cat /etc/zone9/api-url 2>/dev/null || echo https://zone9.cloud/api/v1)"
API_URL="${API_URL%/}"
STATE="${ZONE9_STATE_DIR:-/var/lib/zone9}"
ENV_FILE="${ZONE9_LB_ENV:-/etc/zone9/lb.env}"
SERIAL_FILE="${ZONE9_SERIAL_FILE:-/sys/class/dmi/id/product_serial}"
log() { logger -t zone9-lb-bootstrap "$*"; printf 'zone9-lb-bootstrap: %s\n' "$*" > /dev/console 2>/dev/null || true; }

mkdir -p "$STATE" /etc/zone9

[ -x /usr/local/sbin/zone9-guest-net ] && /usr/local/sbin/zone9-guest-net || true

start_daemon() {
  systemctl enable --now haproxy >/dev/null 2>&1 || true
  systemctl enable zone9-lb >/dev/null 2>&1 || true
  systemctl restart zone9-lb
}

serial="$(cat "$SERIAL_FILE" 2>/dev/null || true)"
case "$serial" in
  z9:*) token="${serial#z9:}" ;;
  *) token="" ;;
esac

# Already enrolled and no new token: just make sure the daemon runs.
if [ -z "$token" ]; then
  if [ -s "$ENV_FILE" ]; then start_daemon; log "identity present; daemon started"
  else log "no identity and no bootstrap token: this VM was not created by the panel"; fi
  exit 0
fi
marker="$STATE/lb.$(printf '%s' "$token" | cksum | cut -d' ' -f1).done"
if [ -f "$marker" ]; then
  [ -s "$ENV_FILE" ] && start_daemon
  exit 0
fi

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

Z9_KIND=""; Z9_LB_ID=""; Z9_NODE_ID=""; Z9_DEVICE_TOKEN=""
while IFS='=' read -r k v; do
  case "$k" in
    Z9_KIND|Z9_LB_ID|Z9_NODE_ID|Z9_DEVICE_TOKEN) eval "$k=\$v" ;;
  esac
done < "$tmp"

[ "$Z9_KIND" = "lb-enroll" ] || { log "refusing bootstrap kind '$Z9_KIND': this image is a load balancer"; exit 1; }
[ -n "$Z9_DEVICE_TOKEN" ] || { log "incomplete lb-enroll payload"; exit 1; }

umask 077
printf 'ZONE9_LB_DEVICE_TOKEN=%s\nZONE9_LB_ID=%s\nZONE9_LB_NODE_ID=%s\n' \
  "$Z9_DEVICE_TOKEN" "$Z9_LB_ID" "$Z9_NODE_ID" > "$ENV_FILE"
printf 'kind=%s\nat=%s\n' "$Z9_KIND" "$(date -u +%FT%TZ)" > "$marker"
start_daemon
log "enrolled: lb=$Z9_LB_ID node=$Z9_NODE_ID; daemon started"

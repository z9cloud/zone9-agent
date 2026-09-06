#!/bin/sh
# zone9-s3-bootstrap — the object storage appliance ("Nesne Depolama" node, ADR-040).
#
# One VM per store node, with a leg in the customer's private network and NO public
# address: traffic reaches it through the customer's load balancer. It runs Garage;
# the configuration is NOT written by hand and is NOT pushed by the panel — the
# zone9-s3 daemon pulls it with the VM's own identity and applies it through
# Garage's local admin API.
#
# This script runs on every boot (cloud-init per-boot hook) and does three things:
#
#   1. Apply the route policy (shared with every zone9 image).
#   2. Make sure Garage's directories exist. There is only ONE disk: the panel sizes
#      the root disk as "package disk + store capacity" and cloud-init grows the
#      filesystem, so there is nothing to partition, format or mount here.
#   3. Enroll, once: read the single-use bootstrap token from SMBIOS
#      (/sys/class/dmi/id/product_serial, "z9:<token>"), exchange it OUTBOUND over
#      HTTPS for the VM's long-lived identity, write it to /etc/zone9/s3.env and
#      start the daemon. The panel deletes the payload once it is handed over.
#
# No login on this VM (no sshd, no getty): the serial console is the only place an
# operator can read what happened, so everything is logged there too.
set -eu

API_URL="$(cat /etc/zone9/api-url 2>/dev/null || echo https://zone9.cloud/api/v1)"
API_URL="${API_URL%/}"
STATE="${ZONE9_STATE_DIR:-/var/lib/zone9}"
ENV_FILE="${ZONE9_S3_ENV:-/etc/zone9/s3.env}"
SERIAL_FILE="${ZONE9_SERIAL_FILE:-/sys/class/dmi/id/product_serial}"
GARAGE_DIR="${ZONE9_GARAGE_DIR:-/var/lib/garage}"
log() { logger -t zone9-s3-bootstrap "$*"; printf 'zone9-s3-bootstrap: %s\n' "$*" > /dev/console 2>/dev/null || true; }

mkdir -p "$STATE" /etc/zone9 "$GARAGE_DIR"

[ -x /usr/local/sbin/zone9-guest-net ] && /usr/local/sbin/zone9-guest-net || true

# ---------------------------------------------------------------------------
# 1. Storage layout — every boot, cheap
# ---------------------------------------------------------------------------
#
# ONE disk, on purpose. The panel sizes the root disk as "package disk + store
# capacity" and cloud-init grows the filesystem on first boot, so Garage's metadata
# and data both live under /var/lib/garage with nothing to format or mount. A second
# disk would have meant partitioning, mkfs and fstab inside a locked appliance — a
# mechanism whose failure mode is an unbootable VM nobody can log into.
mkdir -p "$GARAGE_DIR/meta" "$GARAGE_DIR/data"
chmod 0700 "$GARAGE_DIR/meta" "$GARAGE_DIR/data"

free_mb="$(df -Pm "$GARAGE_DIR" | awk 'NR==2 {print $4}')"
log "storage: ${free_mb:-?} MB free under $GARAGE_DIR"

# ---------------------------------------------------------------------------
# 2. Updater refresh — best effort, every boot
# ---------------------------------------------------------------------------
# The updater updates the daemon but not itself, so a bug in the updater would
# otherwise be permanent on a locked VM. Verified against the release's SHA256SUMS;
# on any failure the current copy stays.
refresh_updater() {
  base="https://github.com/${ZONE9_AGENT_REPO:-z9cloud/zone9-agent}/releases/latest/download"
  d="$(mktemp -d)"
  if curl -fsSL --max-time 20 -o "$d/u" "$base/zone9-agent-update" \
     && curl -fsSL --max-time 20 -o "$d/sums" "$base/SHA256SUMS" \
     && grep " zone9-agent-update\$" "$d/sums" | sed 's# zone9-agent-update$# u#' > "$d/want" \
     && (cd "$d" && sha256sum -c want >/dev/null 2>&1) \
     && ! cmp -s "$d/u" /usr/local/sbin/zone9-agent-update; then
    install -m 0755 "$d/u" /usr/local/sbin/zone9-agent-update && log "updater refreshed from latest release"
  fi
  rm -rf "$d"
}
refresh_updater || true

# ---------------------------------------------------------------------------
# 3. Enrollment — once per token
# ---------------------------------------------------------------------------
start_daemon() {
  # garage itself is NOT enabled here: it has no config until the daemon writes one,
  # and a service that crash-loops on a missing file makes the journal useless.
  systemctl enable zone9-s3 >/dev/null 2>&1 || true
  systemctl restart zone9-s3
}

serial="$(cat "$SERIAL_FILE" 2>/dev/null || true)"
case "$serial" in
  z9:*) token="${serial#z9:}" ;;
  *) token="" ;;
esac

if [ -z "$token" ]; then
  if [ -s "$ENV_FILE" ]; then start_daemon; log "identity present; daemon started"
  else log "no identity and no bootstrap token: this VM was not created by the panel"; fi
  exit 0
fi
marker="$STATE/s3.$(printf '%s' "$token" | cksum | cut -d' ' -f1).done"
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

Z9_KIND=""; Z9_STORE_ID=""; Z9_NODE_ID=""; Z9_NODE_INDEX=""; Z9_DEVICE_TOKEN=""
while IFS='=' read -r k v; do
  case "$k" in
    Z9_KIND|Z9_STORE_ID|Z9_NODE_ID|Z9_NODE_INDEX|Z9_DEVICE_TOKEN) eval "$k=\$v" ;;
  esac
done < "$tmp"

[ "$Z9_KIND" = "s3-enroll" ] || { log "refusing bootstrap kind '$Z9_KIND': this image is an object storage node"; exit 1; }
[ -n "$Z9_DEVICE_TOKEN" ] || { log "incomplete s3-enroll payload"; exit 1; }

umask 077
printf 'ZONE9_S3_DEVICE_TOKEN=%s\nZONE9_S3_STORE_ID=%s\nZONE9_S3_NODE_ID=%s\nZONE9_S3_NODE_INDEX=%s\n' \
  "$Z9_DEVICE_TOKEN" "$Z9_STORE_ID" "$Z9_NODE_ID" "$Z9_NODE_INDEX" > "$ENV_FILE"
printf 'kind=%s\nat=%s\n' "$Z9_KIND" "$(date -u +%FT%TZ)" > "$marker"
start_daemon
log "enrolled: store=$Z9_STORE_ID node=$Z9_NODE_ID index=$Z9_NODE_INDEX; daemon started"

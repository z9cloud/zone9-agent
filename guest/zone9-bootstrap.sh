#!/bin/sh
# zone9-bootstrap — first-boot configuration for platform images.
#
# How a VM gets its configuration when the hypervisor offers no channel for it:
# Proxmox cloud-init can carry addresses and SSH keys but no files or commands,
# the nodes accept no SSH, and the guest agent's exec is disabled by policy.
# What is left is SMBIOS: the panel writes `z9:<token>` into the VM's serial
# number (`qm set --smbios1 serial=...,base64=1`); this script reads it from
# /sys/class/dmi/id/product_serial and calls the panel OUTBOUND over HTTPS.
# The token is single-use — the panel hands over the payload once and deletes
# it. This is the same idea as a cloud's instance metadata service.
#
# Runs on every boot (cloud-init per-boot hook) and does nothing unless:
#   - a serial with the z9: prefix is present, and
#   - the marker file for that token is absent.
# A failed attempt leaves no marker, so it is retried on the next boot; a
# spent token stays spent, so the operator issues a new one.
#
# Kinds handled:
#   tailscale-gateway   join a tailnet and advertise the VPC's routes
set -eu

PANEL_URL="$(cat /etc/zone9/panel-url 2>/dev/null || echo https://zone9.cloud)"
STATE="${ZONE9_STATE_DIR:-/var/lib/zone9}"
SERIAL_FILE="${ZONE9_SERIAL_FILE:-/sys/class/dmi/id/product_serial}"
LOG="logger -t zone9-bootstrap"

serial="$(cat "$SERIAL_FILE" 2>/dev/null || true)"
case "$serial" in
  z9:*) token="${serial#z9:}" ;;
  *) exit 0 ;;   # not a zone9-bootstrapped VM (or SMBIOS not set yet)
esac

mkdir -p "$STATE"
marker="$STATE/bootstrap.$(printf '%s' "$token" | cksum | cut -d' ' -f1).done"
[ -f "$marker" ] && exit 0

# The network may not be fully up when per-boot scripts run; retry for a while.
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
i=0; code=000
while [ "$i" -lt 30 ]; do
  code="$(curl -sS --max-time 15 -o "$tmp" -w '%{http_code}' \
          -H "Authorization: Bearer $token" "$PANEL_URL/v1/bootstrap?format=env" || echo 000)"
  case "$code" in
    200) break ;;
    401|410) $LOG "panel refused the bootstrap token (HTTP $code): $(head -c 200 "$tmp")"; exit 1 ;;
  esac
  i=$((i+1)); sleep 10
done
[ "$code" = 200 ] || { $LOG "panel unreachable after retries (last HTTP $code)"; exit 1; }

# KEY=value lines; values are validated server-side to a narrow charset.
Z9_KIND=""; Z9_LOGIN_SERVER=""; Z9_AUTH_KEY=""; Z9_ROUTES=""; Z9_HOSTNAME=""
while IFS='=' read -r k v; do
  case "$k" in
    Z9_KIND|Z9_LOGIN_SERVER|Z9_AUTH_KEY|Z9_ROUTES|Z9_HOSTNAME) eval "$k=\$v" ;;
  esac
done < "$tmp"

start_service() {  # $1 = service name; systemd or OpenRC
  if command -v systemctl >/dev/null 2>&1; then systemctl enable --now "$1"
  else rc-update add "$1" default >/dev/null 2>&1 || true; rc-service "$1" start; fi
}

case "$Z9_KIND" in
  tailscale-gateway)
    [ -n "$Z9_LOGIN_SERVER" ] && [ -n "$Z9_AUTH_KEY" ] && [ -n "$Z9_ROUTES" ] \
      || { $LOG "incomplete tailscale-gateway payload"; exit 1; }
    # A subnet router forwards; persist so it survives a reboot.
    printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' > /etc/sysctl.d/99-zone9-gateway.conf
    sysctl -q -p /etc/sysctl.d/99-zone9-gateway.conf
    start_service tailscaled
    # --accept-dns=false: this is a router, not a workstation; its resolver stays
    # the platform's. --reset: apply exactly these flags, ignore leftovers.
    tailscale up --reset \
      --login-server "$Z9_LOGIN_SERVER" \
      --authkey "$Z9_AUTH_KEY" \
      --advertise-routes "$Z9_ROUTES" \
      --hostname "${Z9_HOSTNAME:-zone9-gateway}" \
      --accept-dns=false
    $LOG "tailscale-gateway up: routes=$Z9_ROUTES login=$Z9_LOGIN_SERVER"
    ;;
  *) $LOG "unknown bootstrap kind: $Z9_KIND"; exit 1 ;;
esac

printf 'kind=%s\nat=%s\n' "$Z9_KIND" "$(date -u +%FT%TZ)" > "$marker"

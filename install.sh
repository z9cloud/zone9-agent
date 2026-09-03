#!/bin/sh
# zone9-agent installer — https://get.zone9.cloud | sh
#
# What it does: downloads the binary, installs it into /usr/local/bin, and defines
# a systemd service.
# What it does NOT do: register with the panel. Registration is a separate and
# deliberate step:
#   zone9-agent register --token z9r_...
#
# The agent only ever connects OUTBOUND (panel API, 443). No inbound port is opened.
set -eu

PANEL="${ZONE9_PANEL_URL:-https://zone9.cloud}"
BIN_DIR="${ZONE9_BIN_DIR:-/usr/local/bin}"
CONF_DIR="${ZONE9_CONF_DIR:-/etc/zone9}"

say() { printf '  %s\n' "$1"; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo sh -c \"curl -fsSL $PANEL/install.sh | sh\")"

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
[ "$(uname -s)" = "Linux" ] || die "only Linux is supported"

printf '\ninstalling zone9-agent (%s)\n\n' "$ARCH"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The binary comes from the public repository; the panel's source stays private.
REL="${ZONE9_AGENT_RELEASE:-https://github.com/z9cloud/zone9-agent/releases/latest/download}"
say "downloading binary…"
curl -fsSL "$REL/zone9-agent-linux-$ARCH" -o "$TMP/zone9-agent" \
  || die "download failed: $REL/zone9-agent-linux-$ARCH"
chmod 0755 "$TMP/zone9-agent"
install -m 0755 "$TMP/zone9-agent" "$BIN_DIR/zone9-agent"
say "installed: $BIN_DIR/zone9-agent"

mkdir -p "$CONF_DIR"
chmod 0700 "$CONF_DIR"

if [ ! -f "$CONF_DIR/regions.yaml" ]; then
  cat > "$CONF_DIR/regions.yaml" <<'YAML'
# Region definition — your Proxmox credentials stay ON THIS MACHINE and are never
# sent to the panel. Tokens are read from an env file (see token_secret_env below).
regions:
  - id: CHANGE_ME              # the region id shown in the panel
    display_name: "Region"
    enabled: true
    access: agent
    proxmox:
      api_url: https://127.0.0.1:8006
      token_id: zone9@pve!ctl
      token_secret_env: ZONE9_PVE_TOKEN
      tls_insecure: true
    storage:
      vm_storage: local-lvm
    network:
      mgmt_bridge: vmbr0
YAML
  chmod 0600 "$CONF_DIR/regions.yaml"
  say "example config written: $CONF_DIR/regions.yaml"
fi

cat > /etc/systemd/system/zone9-agent.service <<UNIT
[Unit]
Description=zone9 agent
Documentation=https://zone9.cloud
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/zone9-agent
EnvironmentFile=-$CONF_DIR/agent.env
Environment=ZONE9_PANEL_URL=$PANEL
Restart=always
RestartSec=5
# The agent only connects outbound; its access to the local filesystem is kept narrow.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$CONF_DIR
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
say "systemd service defined: zone9-agent"

cat <<NEXT

Installed. Two steps remain:

  1) Edit $CONF_DIR/regions.yaml (region id, Proxmox address) and put the Proxmox
     token in $CONF_DIR/agent.env:
       ZONE9_PVE_TOKEN=<secret>

  2) Pair it using the registration token from the panel:
       zone9-agent register --token z9r_...
       systemctl enable --now zone9-agent

NEXT

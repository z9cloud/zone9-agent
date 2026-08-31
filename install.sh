#!/bin/sh
# zone9-agent kurulumu — https://get.zone9.cloud | sh
#
# Ne yapar: binary'yi indirir, /usr/local/bin'e kurar, systemd servisini tanımlar.
# Ne YAPMAZ: panele kaydolmaz. Kayıt ayrı ve bilinçli bir adımdır:
#   zone9-agent register --token z9r_...
#
# Agent yalnızca DIŞARI bağlanır (panel API'si, 443). İçeri port açılmaz.
set -eu

PANEL="${ZONE9_PANEL_URL:-https://zone9.cloud}"
BIN_DIR="${ZONE9_BIN_DIR:-/usr/local/bin}"
CONF_DIR="${ZONE9_CONF_DIR:-/etc/zone9}"

say() { printf '  %s\n' "$1"; }
die() { printf 'hata: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root olarak çalıştırın (sudo sh -c \"curl -fsSL $PANEL/install.sh | sh\")"

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "desteklenmeyen mimari: $(uname -m)" ;;
esac
[ "$(uname -s)" = "Linux" ] || die "yalnızca Linux desteklenir"

printf '\nzone9-agent kuruluyor (%s)\n\n' "$ARCH"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Binary public depodan gelir; panel private kalır.
REL="${ZONE9_AGENT_RELEASE:-https://github.com/z9cloud/zone9-agent/releases/latest/download}"
say "binary indiriliyor…"
curl -fsSL "$REL/zone9-agent-linux-$ARCH" -o "$TMP/zone9-agent" \
  || die "indirilemedi: $REL/zone9-agent-linux-$ARCH"
chmod 0755 "$TMP/zone9-agent"
install -m 0755 "$TMP/zone9-agent" "$BIN_DIR/zone9-agent"
say "kuruldu: $BIN_DIR/zone9-agent"

mkdir -p "$CONF_DIR"
chmod 0700 "$CONF_DIR"

if [ ! -f "$CONF_DIR/regions.yaml" ]; then
  cat > "$CONF_DIR/regions.yaml" <<'YAML'
# Region tanımı — Proxmox erişim bilgileri BU MAKİNEDE kalır, panele gönderilmez.
# Token'lar env dosyasından okunur (aşağıdaki token_secret_env).
regions:
  - id: CHANGE_ME              # panelde gördüğünüz region kimliği
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
  say "örnek config yazıldı: $CONF_DIR/regions.yaml"
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
# Agent yalnızca dışarı bağlanır; yerel dosya sistemine erişimi dar tutulur.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$CONF_DIR
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
say "systemd servisi tanımlandı: zone9-agent"

cat <<NEXT

Kurulum tamam. Sıradaki iki adım:

  1) $CONF_DIR/regions.yaml dosyasını düzenleyin (region kimliği, Proxmox adresi)
     ve Proxmox token'ını $CONF_DIR/agent.env içine yazın:
       ZONE9_PVE_TOKEN=<secret>

  2) Panelden aldığınız kayıt token'ı ile eşleştirin:
       zone9-agent register --token z9r_...
       systemctl enable --now zone9-agent

NEXT

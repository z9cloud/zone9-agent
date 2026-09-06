#!/usr/bin/env bash
# zone9 image template builder — TWO PHASES.
#
# Why this script exists: building a template by hand produced a broken template
# twice in a row. In one, the routing script was installed as a systemd unit that
# was enabled and never fired. In the other, `cloud-init clean` ran after the hook
# was installed and silently deleted it — it removes everything under /var/lib/cloud
# except `seed`. Both were discovered only when a customer VM turned out to be
# unreachable. This script writes into the image WITHOUT EVER BOOTING IT, so
# neither trap can occur.
#
# Why TWO phases: writing into a disk image needs libguestfs, which pulls in ~100
# packages (ghostscript, x11-common, syslinux, fonts). None of that belongs on a
# hypervisor. So:
#
#   build   needs libguestfs, does NOT need Proxmox. Runs on any x86_64 Linux box.
#           Output: a single qcow2 file.
#   import  needs Proxmox, does NOT need libguestfs. Uses only `qm` and `qemu-img`,
#           both already present on every node. Installs nothing.
#
# Two kinds of image are built here:
#
#   distro     a customer server template (ubuntu/debian/rocky): cloud-init makes
#              users, sshd stays, the serial console is enabled.
#   appliance  a zone9 product VM — `gateway` (Ağ Geçidi) or `lb` (Yük dengeleyici).
#              Nobody logs into these: sshd and snapd are removed, cloud-init makes
#              no users, every getty is masked. They receive their instructions from
#              the panel over an outbound HTTPS call (SMBIOS bootstrap token), so a
#              broken one is never repaired — it is deleted and recreated.
#
# Appliances used to be built by hand, booted, and typed into. That produced two
# broken templates in a row (a leftover Ceph image made the disk attach fail and the
# VM PXE-booted; and the disk was named vm-<id>-disk-1, not -disk-0). Building them
# here removes the boot, the login and the guesswork.
#
# --- on the build host (once: apt install libguestfs-tools) ---
#   ./build-template.sh build debian-12
#   ./build-template.sh build ubuntu-24.04 --k3s
#   ./build-template.sh build gateway
#   ./build-template.sh build lb
#   scp /var/tmp/zone9-templates/z9-debian-12.qcow2 root@<node>:/var/tmp/
#
# --- on the Proxmox node ---
#   ./build-template.sh import 9031 /var/tmp/z9-debian-12.qcow2
#
# If the template's disk lands on shared storage (Ceph/NFS), it is built once on
# one node and can be cloned from every node in the cluster.
set -euo pipefail

WORK="${ZONE9_TEMPLATE_WORKDIR:-/var/tmp/zone9-templates}"
STORAGE="${ZONE9_TEMPLATE_STORAGE:-Ceph-SSD}"
BRIDGE="${ZONE9_TEMPLATE_BRIDGE:-vmbr0}"
# Set inside cmd_build, removed by the EXIT trap below. It has to live at file
# scope: the trap fires after the function's locals are gone.
HOOK_TMP=""
RESOLV_TMP=""
# virt-customize arguments; the appliance helpers append to this.
ARGS=()
# The image is built under a .partial name and only renamed once virt-customize has
# succeeded. So a file named z9-*.qcow2 is always a finished image: a failed or
# interrupted run cannot leave something behind that looks importable.
PARTIAL=""
trap 'rm -f "${HOOK_TMP:-}" "${PARTIAL:-}" "${RESOLV_TMP:-}"; [ -n "${APP_TMPDIR:-}" ] && rm -rf "$APP_TMPDIR"' EXIT

GUEST_BASE_URL="${ZONE9_GUEST_BASE_URL:-https://raw.githubusercontent.com/z9cloud/zone9-agent/main/guest}"
# The appliance daemons and the updater ship as release assets of the same repo.
RELEASE_BASE_URL="${ZONE9_RELEASE_BASE_URL:-https://github.com/z9cloud/zone9-agent/releases/latest/download}"
API_URL="${ZONE9_API_URL:-https://zone9.cloud/api/v1}"
APPLIANCE_DISK_GB="${ZONE9_APPLIANCE_DISK_GB:-12}"
# Temp files for the appliance branch; removed by the EXIT trap.
APP_TMPDIR=""

usage() {
  cat >&2 <<EOF
usage:
  $0 build  <ubuntu-24.04|ubuntu-22.04|debian-12|rocky-9> [--k3s]
  $0 build  <gateway|lb>          zone9 appliance (locked: no login, no sshd)
  $0 import <vmid> <z9-*.qcow2>

environment:
  ZONE9_TEMPLATE_WORKDIR   working directory      (default: /var/tmp/zone9-templates)
  ZONE9_TEMPLATE_STORAGE   Proxmox storage        (default: Ceph-SSD)
  ZONE9_TEMPLATE_BRIDGE    bridge for the template (default: vmbr0)
  ZONE9_GUEST_NET          path to zone9-guest-net.sh; downloaded if unset
  ZONE9_API_URL            panel API the appliance calls (default: https://zone9.cloud/api/v1)
  ZONE9_APPLIANCE_DISK_GB  appliance disk size    (default: 12)
EOF
  exit 1
}

# Which nameservers the appliance should use while installing packages.
#
# Not a hardcoded public resolver: many networks allow outbound HTTPS but block UDP/53
# to the internet, so 1.1.1.1 fails while the site's own resolver works. Take what this
# host actually uses. On systemd-resolved machines /etc/resolv.conf points at the local
# stub (127.0.0.53), which is meaningless inside the appliance — the real upstreams are
# in /run/systemd/resolve/resolv.conf, so that file is read first.
host_resolvers() {
  if [ -n "${ZONE9_TEMPLATE_DNS:-}" ]; then
    printf '%s\n' $ZONE9_TEMPLATE_DNS; return
  fi
  { [ -r /run/systemd/resolve/resolv.conf ] && cat /run/systemd/resolve/resolv.conf
    [ -r /etc/resolv.conf ] && cat /etc/resolv.conf
  } 2>/dev/null \
    | awk '/^nameserver/ && $2 !~ /^127\./ && $2 !~ /:/ {print $2}' \
    | awk '!seen[$0]++' | head -3
}

# Çalışma dizini kullanılabilir mi: VAR, YAZILABİLİR ve YETERLİ YER var mı.
#
# Bu kontrol indirmelerden ÖNCE koşar. Sonra koşuyordu ve sonucu şuydu: dizin dolu ya
# da başka bir kullanıcıya aitse ilk curl "(23) Failure writing output to destination"
# ile düşüyor, sebebi hiçbir yerde yazmıyordu (prod'da yaşandı).
ensure_workdir() {
  local need_gb="${1:-1}"
  mkdir -p "$WORK" 2>/dev/null || {
    echo "çalışma dizini oluşturulamadı: $WORK" >&2
    echo "başka bir yer seçin:  ZONE9_TEMPLATE_WORKDIR=\$HOME/tpl $0 ..." >&2
    exit 1; }
  if ! ( : > "$WORK/.z9write" ) 2>/dev/null; then
    echo "çalışma dizinine yazılamıyor: $WORK" >&2
    ls -ld "$WORK" >&2
    echo "sahibi başka bir kullanıcıysa dizini silin (sudo rm -rf $WORK) ya da" >&2
    echo "başka bir yer seçin:  ZONE9_TEMPLATE_WORKDIR=\$HOME/tpl $0 ..." >&2
    exit 1
  fi
  rm -f "$WORK/.z9write"
  local free_kb
  free_kb="$(df -Pk "$WORK" | awk 'NR==2 {print $4}')"
  if [ -n "$free_kb" ] && [ "$free_kb" -lt $((need_gb * 1024 * 1024)) ]; then
    printf 'yer yetmiyor (%s): %d GB boş, ~%d GB gerekli.\n' \
      "$WORK" "$((free_kb / 1024 / 1024))" "$need_gb" >&2
    df -h "$WORK" >&2
    echo "diski büyütün, ZONE9_TEMPLATE_WORKDIR'ı daha büyük bir bölüme alın ya da" >&2
    echo "önbelleği silin:  rm -f $WORK/*.img $WORK/*.qcow2" >&2
    exit 1
  fi
}

# Locate a guest script. When build-template.sh is downloaded on its own, its
# dependencies will not be sitting next to it — fetch them rather than failing.
resolve_guest_file() {
  local name="$1"
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$here/$name" ]; then printf '%s' "$here/$name"; return; fi
  local dl="$WORK/$name"
  echo "--> fetching $name from $GUEST_BASE_URL" >&2
  ensure_workdir 1
  curl -fsSL --retry 3 -o "$dl" "$GUEST_BASE_URL/$name" || {
    echo "$name indirilemedi ($GUEST_BASE_URL/$name)" >&2
    echo "ağ engelliyse dosyayı bu betiğin yanına koyun" >&2; exit 1; }
  printf '%s' "$dl"
}

resolve_hook() {
  if [ -n "${ZONE9_GUEST_NET:-}" ]; then
    [ -f "$ZONE9_GUEST_NET" ] || { echo "ZONE9_GUEST_NET not found: $ZONE9_GUEST_NET" >&2; exit 1; }
    printf '%s' "$ZONE9_GUEST_NET"; return
  fi
  resolve_guest_file zone9-guest-net.sh
}


# ------------------------------------------------------------- appliance parts
#
# Everything below turns a plain cloud image into a zone9 appliance. The rules are
# the same for both kinds and they are not negotiable:
#
#   * no login anywhere — sshd removed, cloud-init creates no users, gettys masked.
#     The serial console still PRINTS (the bootstrap script and the daemons log to
#     /dev/console); it just offers no prompt.
#   * snapd removed — it has no job here and snapd.seeded delays every boot by ~3
#     minutes, which delayed the bootstrap call to the panel.
#   * the panel is reached OUTBOUND only; nothing listens for us.

# Writes the lockdown + per-boot wiring shared by every appliance into ARGS.
appliance_common_args() {
  local hook="$1" bootstrap_src="$2" bootstrap_name="$3" hook_name="$4"

  printf '#!/bin/sh\nexec /usr/local/sbin/%s\n' "$bootstrap_name" > "$APP_TMPDIR/per-boot-bootstrap"
  printf '#!/bin/sh\nexec /usr/local/sbin/zone9-guest-net\n'      > "$APP_TMPDIR/per-boot-net"
  printf '%s\n' "$API_URL" > "$APP_TMPDIR/api-url"
  cat > "$APP_TMPDIR/cloud-lockdown.cfg" <<'CFG'
# zone9 appliance: no users, no login anywhere. The panel drives this VM through a
# single-use SMBIOS token; there is nothing here for a person to log in to.
users: []
disable_root: true
ssh_pwauth: false
CFG

  ARGS+=(
    --mkdir '/etc/zone9'
    --upload "$APP_TMPDIR/api-url:/etc/zone9/api-url"
    --upload "$hook:/usr/local/sbin/zone9-guest-net"
    --chmod  '0755:/usr/local/sbin/zone9-guest-net'
    --upload "$bootstrap_src:/usr/local/sbin/$bootstrap_name"
    --chmod  "0755:/usr/local/sbin/$bootstrap_name"
    --mkdir  '/var/lib/cloud/scripts/per-boot'
    --upload "$APP_TMPDIR/per-boot-net:/var/lib/cloud/scripts/per-boot/zone9-guest-net"
    --chmod  '0755:/var/lib/cloud/scripts/per-boot/zone9-guest-net'
    # "zz-" prefix: cloud-init runs per-boot scripts in name order and the appliance
    # bootstrap must run AFTER zone9-guest-net, which decides the default route it
    # depends on. The bootstrap calls guest-net itself too; the name is belt and braces.
    --upload "$APP_TMPDIR/per-boot-bootstrap:/var/lib/cloud/scripts/per-boot/$hook_name"
    --chmod  "0755:/var/lib/cloud/scripts/per-boot/$hook_name"
    --upload "$APP_TMPDIR/cloud-lockdown.cfg:/etc/cloud/cloud.cfg.d/99-zone9-appliance.cfg"
    --run-command 'systemctl disable --now snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true'
    --run-command 'DEBIAN_FRONTEND=noninteractive apt-get purge -y snapd openssh-server 2>/dev/null || true'
    --run-command 'DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true'
    --run-command 'systemctl mask serial-getty@ttyS0.service getty@tty1.service console-getty.service || true'
    --run-command 'passwd -l root || true'
    # The image is still the cloud image's ~2.4 GB root here: the disk is grown at
    # import and the filesystem follows on first boot (cloud-init). So the build has
    # to be tidy, and it has to say so if it is running out of room — an apt failure
    # halfway through would otherwise read as a package problem.
    --run-command 'apt-get clean; rm -rf /var/lib/apt/lists/*'
    --run-command '
      free_mb=$(df -Pm / | awk "NR==2 {print \$4}")
      echo "zone9: ${free_mb} MB free in the template root"
      [ "$free_mb" -ge 200 ] || { echo "zone9 GATE FAILED: only ${free_mb} MB free; the appliance root is too tight" >&2; exit 1; }'
  )
}

# The gates run INSIDE the image, at build time. A missing piece in a locked
# appliance is otherwise discovered only when a customer VM fails to work — and it
# cannot be fixed in place, because there is no way in.
appliance_gate_args() {
  ARGS+=( --run-command '
    fail() { echo "zone9 GATE FAILED: $1" >&2; exit 1; }
    dpkg -l snapd 2>/dev/null | grep -q "^ii" && fail "snapd still installed"
    dpkg -l openssh-server 2>/dev/null | grep -q "^ii" && fail "sshd still installed"
    [ -x /usr/local/sbin/zone9-guest-net ] || fail "routing script missing"
    [ -x /var/lib/cloud/scripts/per-boot/zone9-guest-net ] || fail "routing hook missing"
    [ -s /etc/zone9/api-url ] || fail "api-url missing"
    grep -q "users: \[\]" /etc/cloud/cloud.cfg.d/99-zone9-appliance.cfg || fail "lockdown config missing"
    echo "zone9: common gates passed"' )
}

gateway_args() {
  local hook="$1"
  local bootstrap; bootstrap="$(resolve_guest_file zone9-gateway-bootstrap.sh)"
  ARGS+=(
    # iptables: the egress NAT the gateway writes on every boot. tailscale: the
    # Zero Trust capability, installed but DISABLED — the panel turns it on with a
    # token, and a template that dialled home on its own would be a liability.
    --run-command 'curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg > /usr/share/keyrings/tailscale-archive-keyring.gpg'
    --run-command 'curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list > /etc/apt/sources.list.d/tailscale.list'
    --run-command 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y iptables tailscale'
    --run-command 'systemctl disable tailscaled || true'
  )
  appliance_common_args "$hook" "$bootstrap" zone9-gateway-bootstrap zone9-zz-gateway-bootstrap
  appliance_gate_args
  ARGS+=( --run-command '
    fail() { echo "zone9 GATE FAILED: $1" >&2; exit 1; }
    command -v iptables >/dev/null || fail "iptables missing (egress NAT needs it)"
    command -v tailscale >/dev/null || fail "tailscale missing"
    [ -x /usr/local/sbin/zone9-gateway-bootstrap ] || fail "gateway bootstrap missing"
    [ -x /var/lib/cloud/scripts/per-boot/zone9-zz-gateway-bootstrap ] || fail "gateway hook missing"
    systemctl is-enabled tailscaled 2>/dev/null | grep -q enabled && fail "tailscaled must ship disabled"
    echo "zone9: gateway gates passed"' )
}

lb_args() {
  local hook="$1"
  local bootstrap; bootstrap="$(resolve_guest_file zone9-lb-bootstrap.sh)"

  # zone9-lb ships DISABLED: its EnvironmentFile carries the VM identity, which only
  # exists after the bootstrap token has been exchanged. Starting it earlier would
  # just crash-loop.
  cat > "$APP_TMPDIR/zone9-lb.service" <<'UNIT'
[Unit]
Description=zone9 load balancer daemon (pulls panel config into haproxy)
Documentation=https://github.com/z9cloud/zone9-agent
After=network-online.target haproxy.service
Wants=network-online.target

[Service]
EnvironmentFile=/etc/zone9/lb.env
ExecStart=/usr/local/bin/zone9-lb
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

  # The updater is the agent's, pointed at a different asset: one update mechanism
  # for every zone9 binary, one place where the rollback rules live.
  cat > "$APP_TMPDIR/zone9-agent-update.default" <<'DEF'
ZONE9_AGENT_ASSET=zone9-lb
ZONE9_AGENT_BIN=/usr/local/bin/zone9-lb
ZONE9_AGENT_UNIT=zone9-lb
DEF

  # haproxy's packaged config has no listener and neither does this one; haproxy
  # starts fine that way (verified on 2.8). The daemon overwrites it on its first
  # pull — this file only has to be VALID so the service can come up beforehand.
  cat > "$APP_TMPDIR/haproxy.cfg" <<'CFG'
# zone9-lb writes this file from the panel's configuration. Anything edited here is
# overwritten on the next pull; listeners are managed in Ağ → Yük dengeleyici.
global
    log /dev/log local0
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    user haproxy
    group haproxy

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5s
    timeout client  1h
    timeout server  1h
CFG

  ARGS+=(
    --run-command 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy keepalived'
    # keepalived is for HA (two VMs, one VIP). It ships installed and disabled so
    # enabling HA later is a config change, not a template rebuild.
    --run-command 'systemctl disable keepalived || true'
    --upload "$APP_TMPDIR/haproxy.cfg:/etc/haproxy/haproxy.cfg"
    --run-command 'haproxy -c -q -f /etc/haproxy/haproxy.cfg'
    --run-command "curl -fsSL --retry 3 -o /usr/local/bin/zone9-lb $RELEASE_BASE_URL/zone9-lb-linux-amd64"
    --run-command "curl -fsSL --retry 3 -o /usr/local/sbin/zone9-agent-update $RELEASE_BASE_URL/zone9-agent-update"
    --chmod '0755:/usr/local/bin/zone9-lb'
    --chmod '0755:/usr/local/sbin/zone9-agent-update'
    --upload "$APP_TMPDIR/zone9-agent-update.default:/etc/default/zone9-agent-update"
    --upload "$APP_TMPDIR/zone9-lb.service:/etc/systemd/system/zone9-lb.service"
    # --install writes the units and tries to start the timer; the start half cannot
    # work in a chroot, so the enable is done explicitly afterwards.
    --run-command 'zone9-agent-update --install || true'
    --run-command 'systemctl enable zone9-agent-update.timer || true'
    --run-command 'systemctl disable zone9-lb 2>/dev/null || true'
  )
  appliance_common_args "$hook" "$bootstrap" zone9-lb-bootstrap zone9-zz-lb-bootstrap
  appliance_gate_args
  ARGS+=( --run-command '
    fail() { echo "zone9 GATE FAILED: $1" >&2; exit 1; }
    command -v haproxy >/dev/null || fail "haproxy missing"
    [ -x /usr/local/bin/zone9-lb ] || fail "zone9-lb binary missing"
    /usr/local/bin/zone9-lb --version | grep -q . || fail "zone9-lb does not run"
    [ -x /usr/local/sbin/zone9-lb-bootstrap ] || fail "lb bootstrap missing"
    [ -x /var/lib/cloud/scripts/per-boot/zone9-zz-lb-bootstrap ] || fail "lb hook missing"
    [ -f /etc/systemd/system/zone9-lb.service ] || fail "zone9-lb unit missing"
    grep -q "^ZONE9_AGENT_ASSET=zone9-lb$" /etc/default/zone9-agent-update || fail "updater not pointed at zone9-lb"
    systemctl is-enabled zone9-lb 2>/dev/null | grep -q "^enabled$" && fail "zone9-lb must ship disabled (identity comes at bootstrap)"
    echo "zone9: lb gates passed, zone9-lb $(/usr/local/bin/zone9-lb --version)"' )
}

# ------------------------------------------------------------------ build phase
cmd_build() {
  local distro="${1:-}"; shift || true
  local k3s=0
  for a in "$@"; do
    case "$a" in
      --k3s) k3s=1 ;;
      # A vmid here is a common slip: it belongs to the import phase, and silently
      # ignoring it would let someone believe they had chosen one.
      [0-9]*) echo "the vmid belongs to the import phase: $0 import $a <file.qcow2>" >&2; exit 1 ;;
      *) echo "unknown argument: $a" >&2; usage ;;
    esac
  done
  [ -n "$distro" ] || usage

  local url name mirror appliance=""
  case "$distro" in
    # Appliances are Ubuntu 24.04 underneath; the base is an implementation detail
    # and the name never mentions it (migration 0021 made the same call for the slug).
    gateway|lb) url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"; name="$distro"; mirror="archive.ubuntu.com"; appliance="$distro" ;;
    ubuntu-24.04) url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"; name="ubuntu-24.04"; mirror="archive.ubuntu.com" ;;
    ubuntu-22.04) url="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"; name="ubuntu-22.04"; mirror="archive.ubuntu.com" ;;
    debian-12)    url="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"; name="debian-12"; mirror="deb.debian.org" ;;
    rocky-9)      url="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"; name="rocky-9"; mirror="dl.rockylinux.org" ;;
    *) usage ;;
  esac
  [ "$k3s" = 1 ] && name="$name-k3s"
  if [ -n "$appliance" ] && [ "$k3s" = 1 ]; then
    echo "--k3s makes no sense for an appliance" >&2; exit 1
  fi

  command -v virt-customize >/dev/null || {
    if command -v qm >/dev/null; then
      echo "virt-customize not found — and this looks like a Proxmox node." >&2
      echo "Do not install libguestfs here; it pulls in ~100 packages. Run the" >&2
      echo "build phase on another machine, then copy the qcow2 over and use:" >&2
      echo "    $0 import <vmid> <file.qcow2>" >&2
    else
      echo "virt-customize not found. Install it on this build host:" >&2
      echo "    apt install -y libguestfs-tools     # Debian/Ubuntu" >&2
      echo "    dnf install -y libguestfs-tools-c   # Rocky/RHEL" >&2
    fi
    exit 1; }

  # Yer ve yazma hakkı EN BAŞTA: taban imaj + üzerine paket kurulurken büyüyen kopya.
  # Hata yarı yolda `qemu-img convert` ya da virt-customize içinde çıkarsa, mesaj asıl
  # sebebi değil geçici bir dosyayı gösterir.
  ensure_workdir 12

  local hook; hook="$(resolve_hook)"
  local img="$WORK/$(basename "$url")" out="$WORK/z9-$name.qcow2"

  echo "==> 1/3 downloading cloud image"
  [ -f "$img" ] || curl -fSL --retry 3 -o "$img" "$url"

  echo "==> 2/3 preparing a working copy"
  PARTIAL="$out.partial"
  qemu-img convert -O qcow2 "$img" "$PARTIAL"

  local ns; ns="$(host_resolvers)"
  [ -n "$ns" ] || ns="1.1.1.1
8.8.8.8"
  RESOLV_TMP="$WORK/.resolv.$$"
  printf 'nameserver %s\n' $ns > "$RESOLV_TMP"
  echo "==> 3/3 writing into the image (never booted)"
  echo "    appliance DNS: $(echo $ns | tr '\n' ' ')"
  # The routing policy is installed in two places on purpose. The real script goes
  # to /usr/local/sbin, which `cloud-init clean` does not touch; the per-boot
  # directory gets only a two-line wrapper. If the wrapper is ever wiped, recovery
  # is one line rather than a rebuild.
  HOOK_TMP="$WORK/.per-boot-hook.$$"
  printf '#!/bin/sh\nexec /usr/local/sbin/zone9-guest-net\n' > "$HOOK_TMP"

  ARGS=(
    # Cloud images ship /etc/resolv.conf as a symlink into systemd-resolved's runtime
    # directory, which does not exist inside the libguestfs appliance. Without this,
    # `apt-get update` fails silently and the install reports the far more confusing
    # "Unable to locate package". Put a real resolver in place, and restore whatever
    # the image had once the installs are done — the template must not ship a
    # hardcoded nameserver.
    # Cloud images ship /etc/resolv.conf as a SYMLINK into a runtime dir that does
    # not exist in the appliance; mv would follow it and leave a dangling link that
    # --upload cannot then overwrite. Preserve the link target if it exists, then
    # remove the link so --upload creates a fresh file.
    --run-command '[ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ] && cp /etc/resolv.conf /etc/resolv.conf.z9bak; rm -f /etc/resolv.conf; true'
    --upload "$RESOLV_TMP:/etc/resolv.conf"
    --chmod '0644:/etc/resolv.conf'
    # Fail here, loudly, rather than inside apt — where the same problem surfaces as
    # the far more confusing "Unable to locate package".
    --run-command "getent hosts $mirror >/dev/null 2>&1 || {
        echo; echo 'zone9: the build appliance cannot resolve $mirror.'
        echo 'Its DNS comes from this host. Check that the resolvers printed above'
        echo 'are reachable, or set one explicitly:  ZONE9_TEMPLATE_DNS=10.0.0.53'
        exit 1; }"
    --install qemu-guest-agent
    --run-command 'systemctl enable qemu-guest-agent || true'
  )
  if [ -n "$appliance" ]; then
    APP_TMPDIR="$(mktemp -d "$WORK/.appliance.XXXXXX")"
    case "$appliance" in
      gateway) gateway_args "$hook" ;;
      lb)      lb_args "$hook" ;;
    esac
  else
    ARGS+=(
      --upload "$hook:/usr/local/sbin/zone9-guest-net"
      --chmod  '0755:/usr/local/sbin/zone9-guest-net'
      --mkdir  '/var/lib/cloud/scripts/per-boot'
      --upload "$HOOK_TMP:/var/lib/cloud/scripts/per-boot/zone9-guest-net"
      --chmod  '0755:/var/lib/cloud/scripts/per-boot/zone9-guest-net'
      # Serial console: the panel's console feature is served over this. An appliance
      # gets no getty at all — it only writes to the console.
      --run-command 'systemctl enable serial-getty@ttyS0.service || true'
    )
  fi
  if [ "$k3s" = 1 ]; then
    # The k3s binary is baked in but NOT started: the role (server/agent), the token
    # and the address to join are supplied by cloud-init at first boot. One template
    # then covers every role, and a node does not wait on a download while booting.
    ARGS+=(
      --run-command 'curl -sfL https://get.k3s.io -o /usr/local/bin/k3s-install.sh'
      --chmod '0755:/usr/local/bin/k3s-install.sh'
      --run-command 'INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true /usr/local/bin/k3s-install.sh'
    )
  fi
  # Hand DNS back to the image's own configuration.
  ARGS+=(
    --run-command 'rm -f /etc/resolv.conf'
    # If we had a real file, restore it. Otherwise recreate the symlink these cloud
    # images ship — pointing at systemd-resolved's runtime stub, which the running
    # guest fills in itself at boot.
    --run-command '[ -f /etc/resolv.conf.z9bak ] && mv /etc/resolv.conf.z9bak /etc/resolv.conf || ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf'
  )
  # Reset machine-id so clones do not share an identity (DHCP and systemd key off it).
  ARGS+=( --truncate /etc/machine-id )

  # If the build host is itself a VM, nested virtualisation may be off and libguestfs
  # will fail to find KVM. TCG is slow but works.
  virt-customize -a "$PARTIAL" "${ARGS[@]}" || {
    echo "--> retrying without KVM (slow)"
    LIBGUESTFS_BACKEND_SETTINGS=force_tcg virt-customize -a "$PARTIAL" "${ARGS[@]}"
  }

  mv "$PARTIAL" "$out"
  PARTIAL=""

  cat <<EOF

OK  image ready: $out

Next:
  scp $out root@<node>:/var/tmp/
  # on the node:
  ./build-template.sh import <vmid> /var/tmp/$(basename "$out")
EOF
}

# ----------------------------------------------------------------- import phase
cmd_import() {
  local vmid="${1:-}" file="${2:-}"
  [ -n "$vmid" ] && [ -n "$file" ] || usage
  command -v qm >/dev/null || { echo "this phase runs on a Proxmox node (qm not found)" >&2; exit 1; }
  [ -f "$file" ] || { echo "image not found: $file" >&2; exit 1; }
  qemu-img info "$file" >/dev/null || { echo "image unreadable: $file" >&2; exit 1; }
  if qm config "$vmid" >/dev/null 2>&1; then echo "vmid $vmid already in use" >&2; exit 1; fi
  # Leftover volumes from a destroyed VM with the same id: importdisk would work
  # around them by picking a different name, and a stale cloudinit volume makes
  # `qm set --ide2` fail outright ("already exists"). Both happened on 9040.
  local leftovers; leftovers="$(pvesm list "$STORAGE" --vmid "$vmid" 2>/dev/null | awk 'NR>1 {print $1}')"
  if [ -n "$leftovers" ]; then
    echo "storage $STORAGE still holds volumes for vmid $vmid:" >&2
    printf '  %s\n' $leftovers >&2
    echo "remove them first:  pvesm free <volid>" >&2
    exit 1
  fi

  # The template name comes from the filename, so the build phase's --k3s flag does
  # not have to be repeated here.
  local tpl; tpl="$(basename "$file" .qcow2)"
  case "$tpl" in z9-*) ;; *) echo "expected a z9-*.qcow2 filename, got: $tpl" >&2; exit 1 ;; esac

  echo "==> creating $tpl (vmid $vmid)"
  qm create "$vmid" --name "$tpl" --memory 2048 --cores 2 --cpu host \
    --net0 "virtio,bridge=$BRIDGE" --ostype l26 --scsihw virtio-scsi-single \
    --serial0 socket --vga serial0 --agent 1
  qm importdisk "$vmid" "$file" "$STORAGE" >/dev/null
  # Do NOT assume the disk is named vm-<vmid>-disk-0. On Ceph a destroyed VM can
  # leave its image behind, importdisk then creates -disk-1, and a hardcoded -disk-0
  # makes `qm set` fail entirely: the VM ends up with no disk and PXE-boots. Read
  # back whatever importdisk actually attached as unused0.
  local disk; disk="$(qm config "$vmid" | awk -F': ' '/^unused0/ {print $2}')"
  [ -n "$disk" ] || { echo "importdisk left no unused0 entry; check: pvesm list $STORAGE --vmid $vmid" >&2; exit 1; }
  echo "    disk: $disk"
  qm set "$vmid" --scsi0 "$disk" --boot order=scsi0
  qm set "$vmid" --ide2 "$STORAGE:cloudinit"
  case "$tpl" in
    z9-gateway|z9-lb)
      # Grown here, not in the image: enlarging a qcow2 does not enlarge the
      # filesystem inside it. cloud-init's growpart does that on the clone's first
      # boot, so every VM made from this template comes up with the full disk.
      echo "==> growing the appliance disk to ${APPLIANCE_DISK_GB}G"
      qm resize "$vmid" scsi0 "${APPLIANCE_DISK_GB}G" ;;
  esac
  case "$tpl" in
    z9-gateway|z9-lb)
      qm set "$vmid" --description "zone9 appliance template — ${tpl#z9-} (locked: no login; driven by the panel over SMBIOS bootstrap)" ;;
    *)
      qm set "$vmid" --description "zone9 image template — ${tpl#z9-} (routing policy in a cloud-init per-boot hook)" ;;
  esac
  qm template "$vmid"
  qm config "$vmid"

  case "$tpl" in
    z9-gateway|z9-lb)
      cat <<EOF

OK  $tpl ready (vmid $vmid), disk on $STORAGE (${APPLIANCE_DISK_GB}G).

Next:
  1. VERIFY — do not skip. A locked appliance cannot be repaired later; if something
     is missing you only find out when a customer VM fails. Clone it and look, without
     touching anything inside:

       qm clone $vmid $((vmid + 1)) --full --name z9-verify --storage $STORAGE
       qm set $((vmid + 1)) --net0 virtio,bridge=$BRIDGE,tag=11 \\
         --ipconfig0 ip=<free-ip>/24,gw=<gw> --nameserver 1.1.1.1
       qm start $((vmid + 1)) && sleep 45
       qm guest exec $((vmid + 1)) -- /bin/sh -c "ip -4 -br a | grep -v '^lo'; \\
         dpkg -l snapd 2>/dev/null | grep -c '^ii'; df -h / | tail -1"

     Expected: the address cloud-init gave, '0' (no snapd), and a ${APPLIANCE_DISK_GB}G root.
     'qm terminal' must show NO login: prompt. Then: qm stop / qm destroy the clone.
  2. Map the image in executor/regions.yaml (images.${tpl#z9-}: $vmid) and restart the agent.
EOF
      ;;
    *)
      cat <<EOF

OK  $tpl ready (vmid $vmid), disk on $STORAGE.

Next:
  1. Map the image to this vmid in your region configuration, then restart the agent.
  2. VERIFY — do not skip. Create a server from this image, attach a public IP, and
     inside the guest run:
         ip -4 route
     There must be exactly ONE 'default' line, on the public interface, with the
     RFC1918 routes at metric 100. Two 'default' lines mean the template is incomplete.
EOF
      ;;
  esac
}

case "${1:-}" in
  build)  shift; cmd_build  "$@" ;;
  import) shift; cmd_import "$@" ;;
  *) usage ;;
esac

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
# --- on the build host (once: apt install libguestfs-tools) ---
#   ./build-template.sh build debian-12
#   ./build-template.sh build ubuntu-24.04 --k3s
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
HOOK_URL="${ZONE9_GUEST_NET_URL:-https://raw.githubusercontent.com/z9cloud/zone9-agent/main/guest/zone9-guest-net.sh}"

usage() {
  cat >&2 <<EOF
usage:
  $0 build  <ubuntu-24.04|ubuntu-22.04|debian-12|rocky-9> [--k3s]
  $0 import <vmid> <z9-*.qcow2>

environment:
  ZONE9_TEMPLATE_WORKDIR   working directory      (default: /var/tmp/zone9-templates)
  ZONE9_TEMPLATE_STORAGE   Proxmox storage        (default: Ceph-SSD)
  ZONE9_TEMPLATE_BRIDGE    bridge for the template (default: vmbr0)
  ZONE9_GUEST_NET          path to zone9-guest-net.sh; downloaded if unset
EOF
  exit 1
}

# Locate the guest routing script. When build-template.sh is downloaded on its own,
# its dependency will not be sitting next to it — fetch it rather than failing.
resolve_hook() {
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -n "${ZONE9_GUEST_NET:-}" ]; then
    [ -f "$ZONE9_GUEST_NET" ] || { echo "ZONE9_GUEST_NET not found: $ZONE9_GUEST_NET" >&2; exit 1; }
    printf '%s' "$ZONE9_GUEST_NET"; return
  fi
  if [ -f "$here/zone9-guest-net.sh" ]; then
    printf '%s' "$here/zone9-guest-net.sh"; return
  fi
  local dl="$WORK/zone9-guest-net.sh"
  echo "--> fetching zone9-guest-net.sh from $HOOK_URL" >&2
  mkdir -p "$WORK"
  curl -fsSL --retry 3 -o "$dl" "$HOOK_URL" || {
    echo "could not download the guest routing script; place it next to this file" >&2
    echo "or point ZONE9_GUEST_NET at it" >&2; exit 1; }
  printf '%s' "$dl"
}

# ------------------------------------------------------------------ build phase
cmd_build() {
  local distro="${1:-}"; shift || true
  local k3s=0
  for a in "$@"; do [ "$a" = "--k3s" ] && k3s=1; done
  [ -n "$distro" ] || usage

  local url name
  case "$distro" in
    ubuntu-24.04) url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"; name="ubuntu-24.04" ;;
    ubuntu-22.04) url="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"; name="ubuntu-22.04" ;;
    debian-12)    url="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"; name="debian-12" ;;
    rocky-9)      url="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"; name="rocky-9" ;;
    *) usage ;;
  esac
  [ "$k3s" = 1 ] && name="$name-k3s"

  command -v virt-customize >/dev/null || {
    echo "virt-customize not found. Run this phase on a build host, NOT on a" >&2
    echo "Proxmox node:  apt install libguestfs-tools" >&2; exit 1; }

  local hook; hook="$(resolve_hook)"
  mkdir -p "$WORK"
  local img="$WORK/$(basename "$url")" out="$WORK/z9-$name.qcow2"

  echo "==> 1/3 downloading cloud image"
  [ -f "$img" ] || curl -fSL --retry 3 -o "$img" "$url"

  echo "==> 2/3 preparing a working copy"
  qemu-img convert -O qcow2 "$img" "$out"

  echo "==> 3/3 writing into the image (never booted)"
  # The routing policy is installed in two places on purpose. The real script goes
  # to /usr/local/sbin, which `cloud-init clean` does not touch; the per-boot
  # directory gets only a two-line wrapper. If the wrapper is ever wiped, recovery
  # is one line rather than a rebuild.
  local hook_tmp="$WORK/.per-boot-hook.$$"
  printf '#!/bin/sh\nexec /usr/local/sbin/zone9-guest-net\n' > "$hook_tmp"
  trap 'rm -f "$hook_tmp"' EXIT

  local args=(
    --install qemu-guest-agent
    --run-command 'systemctl enable qemu-guest-agent || true'
    --upload "$hook:/usr/local/sbin/zone9-guest-net"
    --chmod  '0755:/usr/local/sbin/zone9-guest-net'
    --mkdir  '/var/lib/cloud/scripts/per-boot'
    --upload "$hook_tmp:/var/lib/cloud/scripts/per-boot/zone9-guest-net"
    --chmod  '0755:/var/lib/cloud/scripts/per-boot/zone9-guest-net'
    # Serial console: the panel's console feature is served over this.
    --run-command 'systemctl enable serial-getty@ttyS0.service || true'
  )
  if [ "$k3s" = 1 ]; then
    # The k3s binary is baked in but NOT started: the role (server/agent), the token
    # and the address to join are supplied by cloud-init at first boot. One template
    # then covers every role, and a node does not wait on a download while booting.
    args+=(
      --run-command 'curl -sfL https://get.k3s.io -o /usr/local/bin/k3s-install.sh'
      --chmod '0755:/usr/local/bin/k3s-install.sh'
      --run-command 'INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true /usr/local/bin/k3s-install.sh'
    )
  fi
  # Reset machine-id so clones do not share an identity (DHCP and systemd key off it).
  args+=( --truncate /etc/machine-id )

  # If the build host is itself a VM, nested virtualisation may be off and libguestfs
  # will fail to find KVM. TCG is slow but works.
  virt-customize -a "$out" "${args[@]}" || {
    echo "--> retrying without KVM (slow)"
    LIBGUESTFS_BACKEND_SETTINGS=force_tcg virt-customize -a "$out" "${args[@]}"
  }

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

  # The template name comes from the filename, so the build phase's --k3s flag does
  # not have to be repeated here.
  local tpl; tpl="$(basename "$file" .qcow2)"
  case "$tpl" in z9-*) ;; *) echo "expected a z9-*.qcow2 filename, got: $tpl" >&2; exit 1 ;; esac

  echo "==> creating $tpl (vmid $vmid)"
  qm create "$vmid" --name "$tpl" --memory 2048 --cores 2 --cpu host \
    --net0 "virtio,bridge=$BRIDGE" --ostype l26 --scsihw virtio-scsi-single \
    --serial0 socket --vga serial0 --agent 1
  qm importdisk "$vmid" "$file" "$STORAGE" >/dev/null
  qm set "$vmid" --scsi0 "$STORAGE:vm-$vmid-disk-0" --boot order=scsi0
  qm set "$vmid" --ide2 "$STORAGE:cloudinit"
  qm set "$vmid" --description "zone9 image template — ${tpl#z9-} (routing policy in a cloud-init per-boot hook)"
  qm template "$vmid"
  qm config "$vmid"

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
}

case "${1:-}" in
  build)  shift; cmd_build  "$@" ;;
  import) shift; cmd_import "$@" ;;
  *) usage ;;
esac

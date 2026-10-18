#!/bin/sh
#
# Last updated Time-stamp: "Sunday, 18-Oct-26 19:31:58 mb"
#
# bhyve-debian-vm.sh
# Automates the steps in FreeBSD_Bhyve_DebianVM.org:
#   Debian VM on a FreeBSD host using vm-bhyve, a private NAT'd bridge
#   (host is on Wi-Fi), PF for NAT, base-system tools only (sh, fetch, sha256).
#
# Usage: ./bhyve-debian-vm.sh <command>
#   host-prep   install packages, rc.conf / sysctl.conf, load kernel modules
#   init        create ZFS dataset, vm init, copy templates
#   network     bridge, vm-bhyve switch, IP forwarding, PF NAT
#   iso         download + verify Debian netinst ISO
#   create      create the VM and write its vm-bhyve config
#   install     start the Debian installer (then attach with: console)
#   console     attach to the VM serial console (disconnect with ~.)
#   all         host-prep, init, network, iso, create, install
#   destroy     power off and delete the VM (keeps ISO and host setup)
#
# Every setting below can be overridden from the environment, e.g.
#   EXT_IF=wlan0 VM_NAME=k8s-node VM_MEM=4G ./bhyve-debian-vm.sh all

set -eu

# ----------------------------------------------------------------
# Settings
: "${VM_NAME:=k8s-node}"
: "${VM_DISK:=40G}"
: "${VM_CPU:=2}"
: "${VM_MEM:=2G}"

: "${ZFS_DATASET:=zroot/bhyve}"

: "${EXT_IF:=wlan0}"            # internet-facing (Wi-Fi) interface
: "${BRIDGE_IF:=bridge0}"
: "${SWITCH_NAME:=private}"     # vm-bhyve manual switch name
: "${HOST_IP:=10.0.0.1}"        # host side of the bridge = VM gateway
: "${NETMASK:=255.255.255.0}"
: "${VIRT_NET:=10.0.0.0/24}"

: "${DEBIAN_VER:=13.7.0}"
: "${ISO_NAME:=debian-${DEBIAN_VER}-amd64-netinst.iso}"
# "current" only carries the latest point release. If DEBIAN_VER is older,
# point ISO_URL at the cdimage archive instead.
: "${ISO_URL:=https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/${ISO_NAME}}"
: "${SKIP_VERIFY:=0}"           # 1 = skip SHA256 check of the ISO
: "${FORCE_PF:=0}"              # 1 = replace an existing, unmanaged /etc/pf.conf (backed up)

KLD_MODULES="vmm nmdm if_bridge if_tap"
PF_MARKER="# managed by bhyve-debian-vm.sh"

# -----------------------------------------------------------------
# Helpers
log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "run as root"
    [ "$(uname -s)" = "FreeBSD" ] || die "this script is for FreeBSD hosts"
}

# Append a line to a file only if it is not already present.
ensure_line() {
    _file=$1; _line=$2
    touch "$_file"
    grep -qxF "$_line" "$_file" || printf '%s\n' "$_line" >> "$_file"
}

bhyve_dir() {
    zfs get -H -o value mountpoint "$ZFS_DATASET"
}

vm_exists() {
    vm list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$VM_NAME"
}

# -------------------------------------------------------------------
# Steps
host_prep() {
    log "Installing vm-bhyve and edk2-bhyve"
    pkg update -q
    pkg install -y vm-bhyve edk2-bhyve

    log "Updating /etc/rc.conf"
    sysrc vm_enable="YES"
    sysrc vm_dir="zfs:${ZFS_DATASET}"
    for m in $KLD_MODULES; do
        sysrc kld_list+=" $m"
    done

    log "Setting net.link.tap.up_on_open"
    ensure_line /etc/sysctl.conf "net.link.tap.up_on_open=1"

    log "Loading kernel modules"
    for m in $KLD_MODULES; do
        kldload -n "$m" 2>/dev/null || warn "could not load $m (may be built in or merged into another module)"
    done
    sysctl net.link.tap.up_on_open=1 >/dev/null 2>&1 || warn "net.link.tap.up_on_open not settable right now"
}

init_hypervisor() {
    log "Creating ZFS dataset ${ZFS_DATASET}"
    zfs list -H -o name "$ZFS_DATASET" >/dev/null 2>&1 || zfs create "$ZFS_DATASET"

    log "Running vm init"
    vm init

    log "Copying default guest templates"
    _dir=$(bhyve_dir)
    mkdir -p "${_dir}/.templates"
    cp -n /usr/local/share/examples/vm-bhyve/* "${_dir}/.templates/" 2>/dev/null || true
}

setup_network() {
    log "Creating ${BRIDGE_IF} with ${HOST_IP}/${NETMASK}"
    ifconfig "$BRIDGE_IF" >/dev/null 2>&1 || ifconfig "$BRIDGE_IF" create
    ifconfig "$BRIDGE_IF" inet "$HOST_IP" netmask "$NETMASK" up

    # persist across reboots
    sysrc cloned_interfaces+=" $BRIDGE_IF"
    sysrc "ifconfig_${BRIDGE_IF}=inet ${HOST_IP} netmask ${NETMASK} up"

    log "Creating vm-bhyve manual switch '${SWITCH_NAME}' on ${BRIDGE_IF}"
    if vm switch list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$SWITCH_NAME"; then
        log "switch already exists"
    else
        vm switch create -t manual -b "$BRIDGE_IF" "$SWITCH_NAME"
    fi

    log "Enabling IPv4 forwarding"
    sysctl net.inet.ip.forwarding=1 >/dev/null
    ensure_line /etc/sysctl.conf "net.inet.ip.forwarding=1"

    setup_pf
}

setup_pf() {
    _pf=/etc/pf.conf
    if [ -f "$_pf" ] && ! grep -qF "$PF_MARKER" "$_pf"; then
        if [ "$FORCE_PF" = "1" ]; then
            _bak="${_pf}.bak.$(date +%Y%m%d%H%M%S)"
            cp "$_pf" "$_bak"
            log "Existing ${_pf} backed up to ${_bak}"
        else
            die "${_pf} exists and is not managed by this script. Merge the NAT rule by hand or re-run with FORCE_PF=1 (backs it up first)."
        fi
    fi

    log "Writing ${_pf}"
    cat > "$_pf" <<EOF
${PF_MARKER}
ext_if="${EXT_IF}"
virt_net="${VIRT_NET}"

# Skip filtering on loopback and the VM bridge
set skip on lo0
set skip on ${BRIDGE_IF}

# NAT VM traffic out over Wi-Fi
nat on \$ext_if from \$virt_net to any -> (\$ext_if)

# Pass all other traffic (tighten to taste)
pass out all
pass in all
EOF

    pfctl -nf "$_pf" || die "pf.conf failed validation"
    sysrc pf_enable="YES"
    service pf restart
}

fetch_iso() {
    _iso_dir="$(bhyve_dir)/.iso"
    mkdir -p "$_iso_dir"
    _iso="${_iso_dir}/${ISO_NAME}"

    if [ -f "$_iso" ]; then
        log "ISO already present: ${_iso}"
        return 0
    fi

    log "Downloading ${ISO_URL}"
    fetch -o "$_iso" "$ISO_URL" || { rm -f "$_iso"; die "ISO download failed (check DEBIAN_VER / ISO_URL)"; }

    # Guard against the "got an HTML page instead of the ISO" case from the notes
    _size=$(stat -f %z "$_iso")
    if [ "$_size" -lt 104857600 ]; then
        rm -f "$_iso"
        die "downloaded file is only ${_size} bytes - not an ISO. Set ISO_URL to the direct .iso link."
    fi

    if [ "$SKIP_VERIFY" = "1" ]; then
        warn "skipping checksum verification"
        return 0
    fi

    log "Verifying SHA256"
    _sums=$(fetch -qo - "${ISO_URL%/*}/SHA256SUMS") || { rm -f "$_iso"; die "could not fetch SHA256SUMS (use SKIP_VERIFY=1 to bypass)"; }
    _want=$(printf '%s\n' "$_sums" | awk -v f="$ISO_NAME" '$2 == f {print $1}')
    [ -n "$_want" ] || { rm -f "$_iso"; die "no checksum entry for ${ISO_NAME}"; }
    _got=$(sha256 -q "$_iso")
    [ "$_want" = "$_got" ] || { rm -f "$_iso"; die "checksum mismatch - ISO removed"; }
}

create_vm() {
    if vm_exists; then
        log "VM ${VM_NAME} already exists - leaving it alone"
        return 0
    fi

    log "Creating VM ${VM_NAME} (${VM_DISK} disk)"
    vm create -t linux -s "$VM_DISK" "$VM_NAME"

    _conf="$(bhyve_dir)/${VM_NAME}/${VM_NAME}.conf"
    log "Writing ${_conf}"
    cat > "$_conf" <<EOF
loader="grub"
cpu=${VM_CPU}
memory=${VM_MEM}
network0_type="virtio-net"
network0_switch="${SWITCH_NAME}"
disk0_type="virtio-blk"
disk0_name="disk0.img"
grub_install0="linux /install.amd/vmlinuz console=ttyS0,115200n8 --- console=ttyS0,115200n8; initrd /install.amd/initrd.gz"
EOF
}

install_vm() {
    vm_exists || die "VM ${VM_NAME} does not exist - run 'create' first"
    log "Starting Debian installer for ${VM_NAME}"
    vm install "$VM_NAME" "$ISO_NAME"
    cat <<EOF

Installer is running. Attach with:  $0 console

In the installer:
  - choose "Install" (text mode) at the GRUB screen
  - network: manual -> IP 10.0.0.10, netmask ${NETMASK}, gateway ${HOST_IP}, DNS 1.1.1.1 or 8.8.8.8
  - Software selection: untick desktop environments; tick "SSH server" and "standard system utilities"
  - let it reboot when done; disconnect from the console with ~.
EOF
}

console_vm() {
    TERM=xterm; export TERM
    stty rows 40 cols 120 2>/dev/null || true
    exec vm console "$VM_NAME"
}

destroy_vm() {
    vm_exists || { log "VM ${VM_NAME} not found"; return 0; }
    log "Destroying VM ${VM_NAME}"
    vm poweroff -f "$VM_NAME" 2>/dev/null || true
    vm destroy -f "$VM_NAME"
}

# --------------------------------------------------------------------
# Main
cmd=${1:-}
case "$cmd" in
    host-prep) need_root; host_prep ;;
    init)      need_root; init_hypervisor ;;
    network)   need_root; setup_network ;;
    iso)       need_root; fetch_iso ;;
    create)    need_root; create_vm ;;
    install)   need_root; install_vm ;;
    console)   need_root; console_vm ;;
    destroy)   need_root; destroy_vm ;;
    all)
        need_root
        host_prep
        init_hypervisor
        setup_network
        fetch_iso
        create_vm
        install_vm
        ;;
    *)
        sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac

# --------------------------------------------------------------------
# End

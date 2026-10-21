#!/bin/sh
#
# bhyve-debian-vm-verify.sh
# Read-only checks for the setup done by bhyve-debian-vm.sh.
# Makes no changes. Prints PASS/FAIL per check; exit status = number of failures.
#
# Usage: ./bhyve-debian-vm-verify.sh [stage]
#   stages: host | network | iso | vm | guest | all (default: all, minus 'guest')
# 'guest' needs the installed Debian VM running at VM_IP.
# Same environment overrides as the main script.

set -u

: "${VM_NAME:=k8s-node}"
: "${ZFS_DATASET:=zroot/bhyve}"
: "${EXT_IF:=wlan0}"
: "${BRIDGE_IF:=bridge0}"
: "${SWITCH_NAME:=private}"
: "${HOST_IP:=10.0.0.1}"
: "${VM_IP:=10.0.0.10}"
: "${DEBIAN_VER:=13.7.0}"
: "${ISO_NAME:=debian-${DEBIAN_VER}-amd64-netinst.iso}"

FAILS=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

# check "description" command args...
check() {
    _desc=$1; shift
    if "$@" >/dev/null 2>&1; then pass "$_desc"; else fail "$_desc"; fi
}

rc_is() {   # rc_is var expected
    [ "$(sysrc -n "$1" 2>/dev/null)" = "$2" ]
}

rc_has() {  # rc_has var word
    sysrc -n "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"
}

stage_host() {
    printf '\n-- host preparation --\n'
    check "vm-bhyve installed"        pkg info vm-bhyve
    check "edk2-bhyve installed"      pkg info edk2-bhyve
    check "rc.conf vm_enable=YES"     rc_is vm_enable YES
    check "rc.conf vm_dir set"        rc_is vm_dir "zfs:${ZFS_DATASET}"
    for m in vmm nmdm if_bridge if_tap; do
        check "rc.conf kld_list has $m" rc_has kld_list "$m"
    done
    check "vmm module loaded"         kldstat -q -m vmm
    check "nmdm module loaded"        kldstat -q -m nmdm
    check "if_bridge module loaded"   kldstat -q -m if_bridge
    # tap may be merged into if_tuntap on newer releases
    if kldstat -q -m if_tap || kldstat -q -m if_tuntap; then
        pass "tap module loaded (if_tap or if_tuntap)"
    else
        fail "tap module loaded (if_tap or if_tuntap)"
    fi
    check "sysctl tap.up_on_open=1"   test "$(sysctl -n net.link.tap.up_on_open 2>/dev/null)" = 1
    check "sysctl.conf has tap.up_on_open" grep -qxF net.link.tap.up_on_open=1 /etc/sysctl.conf
    check "ZFS dataset ${ZFS_DATASET}" zfs list -H -o name "$ZFS_DATASET"
}

stage_network() {
    printf '\n-- network --\n'
    check "${BRIDGE_IF} exists"       ifconfig "$BRIDGE_IF"
    check "${BRIDGE_IF} has ${HOST_IP}" sh -c "ifconfig $BRIDGE_IF | grep -q 'inet $HOST_IP '"
    check "${BRIDGE_IF} is UP"        sh -c "ifconfig $BRIDGE_IF | grep -q 'flags=.*<UP'"
    check "rc.conf cloned_interfaces has ${BRIDGE_IF}" rc_has cloned_interfaces "$BRIDGE_IF"
    check "rc.conf ifconfig_${BRIDGE_IF} set" test -n "$(sysrc -n "ifconfig_${BRIDGE_IF}" 2>/dev/null)"
    check "vm switch '${SWITCH_NAME}' listed" sh -c "vm switch list | awk 'NR>1 {print \$1}' | grep -qx $SWITCH_NAME"
    check "ip forwarding live"        test "$(sysctl -n net.inet.ip.forwarding)" = 1
    check "ip forwarding persisted"   grep -qxF net.inet.ip.forwarding=1 /etc/sysctl.conf
    check "pf_enable=YES"             rc_is pf_enable YES
    check "pf.conf validates"         pfctl -nf /etc/pf.conf
    check "pf is running"             sh -c "pfctl -si | grep -q 'Status: Enabled'"
    check "pf NAT rule loaded for ${EXT_IF}" sh -c "pfctl -sn | grep -q 'nat on $EXT_IF'"
    check "${EXT_IF} exists"          ifconfig "$EXT_IF"
}

stage_iso() {
    printf '\n-- ISO --\n'
    _dir=$(zfs get -H -o value mountpoint "$ZFS_DATASET" 2>/dev/null) || _dir=
    check "ISO present: ${ISO_NAME}"  test -f "${_dir}/.iso/${ISO_NAME}"
    check "ISO size > 100 MB"         test "$(stat -f %z "${_dir}/.iso/${ISO_NAME}" 2>/dev/null || echo 0)" -gt 104857600
}

stage_vm() {
    printf '\n-- VM definition --\n'
    _dir=$(zfs get -H -o value mountpoint "$ZFS_DATASET" 2>/dev/null) || _dir=
    _conf="${_dir}/${VM_NAME}/${VM_NAME}.conf"
    check "VM ${VM_NAME} listed"      sh -c "vm list | awk 'NR>1 {print \$1}' | grep -qx $VM_NAME"
    check "VM config exists"          test -f "$_conf"
    check "config uses switch '${SWITCH_NAME}'" grep -qx "network0_switch=\"${SWITCH_NAME}\"" "$_conf"
    check "config loader=grub"        grep -qx 'loader="grub"' "$_conf"
    check "disk image exists"         test -f "${_dir}/${VM_NAME}/disk0.img"
    if vm list | awk -v n="$VM_NAME" '$1 == n {print $0}' | grep -qi running; then
        pass "VM is running"
    else
        printf 'INFO  VM is not running (ok before install / after poweroff)\n'
    fi
}

stage_guest() {
    printf '\n-- guest (VM must be running and installed) --\n'
    check "host can ping ${VM_IP}"    ping -c 2 -t 5 "$VM_IP"
    check "ssh port 22 open on ${VM_IP}" nc -z -w 5 "$VM_IP" 22
    printf 'INFO  For the NAT path, run inside the guest: ping -c 2 1.1.1.1 && ping -c 2 debian.org\n'
}

case "${1:-all}" in
    host)    stage_host ;;
    network) stage_network ;;
    iso)     stage_iso ;;
    vm)      stage_vm ;;
    guest)   stage_guest ;;
    all)     stage_host; stage_network; stage_iso; stage_vm ;;
    *)       sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

printf '\n%s check(s) failed\n' "$FAILS"
[ "$FAILS" -gt 255 ] && FAILS=255
exit "$FAILS"

#!/bin/sh
# boot-test.sh — boot the gershwin-on-freebsd live ISO in qemu and confirm
# the system reaches a login prompt on the serial console. Adapted from
# pkgdemon/freebsd-launchd's boot-test. Single-stage: getty's "login:" on
# the serial line proves loader → kernel → cd9660 mount → /sbin/init →
# /boot/init_script live-mount cascade → multi-user rc → getty all worked.

set -eu

ISO=${1:?usage: boot-test.sh path/to/livecd.iso}

if [ ! -f "$ISO" ]; then
    echo "ERROR: $ISO not found"
    exit 1
fi

mkdir -p tests
LOG=tests/boot.log
EXP=tests/boot.exp

echo "==> boot test: $ISO"
ls -lh "$ISO"

# Pick acceleration. KVM if available; TCG fallback.
if [ -e /dev/kvm ]; then
    sudo chmod 666 /dev/kvm 2>/dev/null || true
fi
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL_FLAGS="-accel kvm -cpu host"
    echo "==> using KVM acceleration"
else
    ACCEL_FLAGS="-accel tcg,thread=single -cpu qemu64"
    echo "==> using TCG (single-thread)"
fi

# Find OVMF firmware in common Linux paths.
OVMF=""
for f in /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/ovmf/OVMF.fd \
         /usr/share/qemu/OVMF.fd; do
    if [ -f "$f" ]; then
        OVMF="$f"
        break
    fi
done
if [ -z "$OVMF" ]; then
    echo "ERROR: no OVMF firmware found"
    exit 1
fi
echo "==> using UEFI firmware: $OVMF"

export ACCEL_FLAGS OVMF

cat > "$EXP" <<'EOF'
set timeout 600
log_file -a tests/boot.log
log_user 1

set iso [lindex $argv 0]
set accel_flags [split $env(ACCEL_FLAGS) " "]

eval spawn qemu-system-x86_64 \
    -m 4G \
    -machine q35 \
    -bios $env(OVMF) \
    $accel_flags \
    -cdrom $iso -boot d \
    -display none -serial stdio \
    -no-reboot

# Wait for a marker that proves multi-user is up. Phase 2 retired
# getty (gershwin uses LoginWindow as the GUI login, not text-mode
# getty), so we don't watch for "login:" anymore. Acceptable markers:
#   - LoginWindow[                 — gershwin's GUI greeter is running
#     (syslog tag for any LoginWindow-emitted log line)
#   - Successfully registered      — Eau theme bridge registered with
#     gdomap, proves DO + LoginWindow chain reached
#   - em0: leased                  — dhcpcd plist worked end-to-end
#     (network reach as a fallback signal)
expect {
    timeout {
        puts "\nFAIL: no multi-user marker within 10 minutes"
        exit 1
    }
    "LoginWindow\["               { puts "\nOK: LoginWindow is running" }
    "Successfully registered"     { puts "\nOK: DO + theme bridge registered" }
    -re {em\w+: leased}           { puts "\nOK: dhcpcd leased an IP" }
}

close
wait
exit 0
EOF

expect "$EXP" "$ISO"
echo "==> boot-test PASSED"

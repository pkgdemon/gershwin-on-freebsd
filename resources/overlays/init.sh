#!/rescue/sh
# /init.sh — runs as a child of /sbin/init via init_script kenv.
#
# Lives at the root of the cd9660 ISO. The kernel mounts cd9660 as /,
# init runs (from /rescue/init since /sbin/init isn't on the cd9660),
# reads init_script kenv from loader.conf, forks, and exec's us. We:
#   - vnode-mount /rootfs.uzip with mdconfig
#   - mount the read-only UFS at /sysroot (lower layer)
#   - mount tmpfs at /upper (writable layer, RAM-scaled, no fixed size)
#   - mount in-kernel unionfs combining them at /sysroot
#   - mount devfs at /sysroot/dev
#   - apply gershwin live-mode tweaks against /sysroot/...
#   - set init_chroot=/sysroot kenv
#   - exit
# init then chroots into /sysroot before continuing normal multi-user
# boot. cd9660 stays mounted as the kernel's actual root, hidden from
# the chroot. Only decompressed pages of rootfs.uzip live in RAM
# (page cache), not the entire compressed image.
#
# Replaces the previous per-subdir nullfs + cp -R model. RAM saving at
# idle is ~15-70 MB (no physical copy of /etc and /var into tmpfs;
# everything is unionfs CoW from the uzip).
#
# Adapted from probono/freebsd-livecd-unionfs init.sh (BSD-2-Clause)
# and the previous gershwin-on-freebsd /boot/init_script.

# === Mount devfs FIRST, then redirect stdio ===
# /sbin/init's open_console() runs BEFORE init mounts devfs at /dev
# (init.c:326-389 reads init_script before mounting /dev), so when init
# tries to open /dev/console for our child it falls back to /var/log/
# init.log (which doesn't exist on read-only cd9660) → /dev/null dup.
# Our inherited stdio is therefore /dev/null, and every echo we make is
# invisible. Kernel printf bypasses /dev/console (writes via cnputc to
# the registered console drivers directly), so kernel messages still
# appear — but our shell output doesn't.
#
# Fix: mount devfs ourselves first, then re-exec stdio onto the now-
# real /dev/console. After this, every echo is visible. init.c's later
# devfs-mount check (line 343) detects /dev is already mounted and
# skips, so no double mount.
mount -t devfs devfs /dev 2>/dev/null
exec </dev/console >/dev/console 2>&1
echo "[init.sh] starting"

# === Monkey patch from kenv (early — runs before unionfs setup) ===
if [ "$(kenv -q monkey_patch_init_script)" != "" ] ; then
  kenv -q -u monkey_patch_init_script # Prevent infinite loop
  echo ""
  echo "Monkey patch init_script requested."
  echo "Looking for a file named init_script on a msdosfs geom with the label MONKEYPATCH"
  echo ""

  echo "Waiting for /dev/msdosfs/MONKEYPATCH to appear..."
  while : ; do
    [ -e "/dev/msdosfs/MONKEYPATCH" ] && echo "found /dev/msdosfs/MONKEYPATCH" && sleep 2 && break
    sleep 2
  done
  mount -t msdosfs "/dev/msdosfs/MONKEYPATCH" /mnt
  if [ -e "/mnt/init_script" ] ; then
    echo "Applying monkey patch..." > /dev/console
    sh /mnt/init_script > /dev/console
  else
    echo "/init_script missing" > /dev/console
  fi
  umount -f /mnt
  exit 0
fi

# === Single-user check ===
if [ "`ps -o command 1 | tail -n 1 | ( read c o; echo ${o} )`" = "-s" ]; then
  echo "==> Running in single-user mode"
  SINGLE_USER="true"
  kenv boot_mute="NO"
  sh
fi

# === Optional silencing (boot_mute) ===
# boot_mute kept as historical off-switch — commented out in
# loader.mute.d/loader.conf during Phase 1/2. If a future build
# re-enables it, this branch overrides our top-of-script redirect to
# /dev/null. For now this branch never fires.
if [ "$(kenv boot_mute 2>/dev/null)" = "YES" ] ; then
  exec 1>>/dev/null 2>&1
else
  echo -e '\e[1;37m' # Bold black letters to increase readability
fi

set -x

# === Defensive module loads (also loaded by loader, but be safe) ===
echo "[init.sh] kldload defensives"
kldload geom_uzip 2>/dev/null || true
kldload unionfs   2>/dev/null || true
kldload tmpfs     2>/dev/null || true

# === Vnode-mount the compressed rootfs ===
# /rootfs.uzip lives at the root of the cd9660 (placed there by build.sh's
# generate_iso). geom_uzip auto-tastes /dev/md0 and produces /dev/md0.uzip.
echo "[init.sh] mdconfig /rootfs.uzip"
mdconfig -a -t vnode -o readonly -f /rootfs.uzip -u 0
echo "[init.sh] waiting for /dev/md0.uzip"
i=0
while [ ! -e /dev/md0.uzip ]; do
    sleep 1
    i=$((i+1))
    if [ "$i" -gt 30 ]; then
        echo "[init.sh] ERROR: /dev/md0.uzip never appeared"
        ls -la /dev/md* 2>/dev/null || true
        halt -p
    fi
done
echo "[init.sh] /dev/md0.uzip appeared after ${i}s"

# === Layer the writable upper over the read-only lower ===
# /sysroot and /upper are pre-created on the cd9660 by build.sh. tmpfs has
# no fixed size — pages allocate on demand from VM, spill to swap under
# pressure. Writes to /sysroot land in /upper (CoW); reads fall through
# to the uzip.
echo "[init.sh] mount ufs /dev/md0.uzip -> /sysroot (lower)"
mount -t ufs -o ro /dev/md0.uzip /sysroot || { echo "[init.sh] FAIL: ufs mount"; halt -p; }
echo "[init.sh] mount tmpfs -> /upper (writable)"
mount -t tmpfs tmpfs /upper            || { echo "[init.sh] FAIL: tmpfs mount"; halt -p; }
echo "[init.sh] mount unionfs /upper -> /sysroot (combined)"
mount -t unionfs /upper /sysroot       || { echo "[init.sh] FAIL: unionfs mount"; halt -p; }
echo "[init.sh] mount devfs -> /sysroot/dev"
mount -t devfs devfs /sysroot/dev      || { echo "[init.sh] FAIL: devfs mount"; halt -p; }
echo "[init.sh] cascade complete"

# === Gershwin live-mode tweaks (post-mount, pre-chroot) ===
# All paths target /sysroot/... since that's where the writable union
# root is. After init exits and chroots, these paths show up as /etc/...

# LoginWindow state file (lastLoggedInUser + lastSession)
mkdir -p /sysroot/Local/Library/Preferences
cat > /sysroot/Local/Library/Preferences/LoginWindow.plist <<\EOF
{
    lastLoggedInUser = admin;
    lastSession = "/System/Library/Scripts/Gershwin.sh";
}
EOF

# === helloSystem-specific console / panic behavior ===
if [ "$(sysctl -q -n kern.consmute)" = "1" ] ; then
  : # No text consoles when console muting is on
else
  # Don't reboot immediately on kernel panic so the user can read it
  sysctl kern.panic_reboot_wait_time=30
fi

# Log the start-hello session output for development debugging
sed -i '' -e 's|# This script is intended to be invoked by a desktop file|exec 1>>/tmp/start-hello.log 2>\&1\nset -x|g' \
    /sysroot/usr/local/bin/start-hello 2>/dev/null || true

# === SMBIOS-derived hostname ===
# /rescue doesn't include xargs; use sed alone to dash-collapse spaces.
SMBIOS_HOST=$(kenv -q "smbios.system.product" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' -e 's| |-|g')
if [ -n "$SMBIOS_HOST" ]; then
    hostname "$SMBIOS_HOST" 2>/dev/null || true
    # Persist via rc.conf so rc.d/hostname doesn't clobber it later
    echo "hostname=\"$SMBIOS_HOST\"" >> /sysroot/etc/rc.conf
fi

# === VirtualBox guest detection ===
PRODUCT=$(kenv -q "smbios.system.product")
if [ "${PRODUCT}" = "VirtualBox" ] ; then
  kldload /sysroot/boot/modules/vboxdrv.ko   2>/dev/null || true
  kldload /sysroot/boot/modules/vboxguest.ko 2>/dev/null || true
  echo 'vboxguest_enable="YES"'   >> /sysroot/etc/rc.conf
  echo 'vboxservice_enable="YES"' >> /sysroot/etc/rc.conf
fi

# === Live-mode rc.conf overrides ===
# CRITICAL: root_rw_mount="NO" prevents /etc/rc.d/root from running
# `mount -uw /` after the chroot. Inside the chroot, mount(8) inspects
# the kernel mount table — which reports the kernel's actual root as
# cd9660 — and dispatches mount_cd9660 -uw, which fails with
# "Operation not supported" and aborts the entire boot. The unionfs
# at /sysroot is already writable (tmpfs upper) so we don't need a
# rw remount. Same fix as freebsd-livecd-unionfs/overlays/etc/rc.conf:14.
#
# kld_list is REASSIGNED (not appended) because FreeBSD sh doesn't
# parse `var+="value"` — it interprets the whole line as a command
# and fails with "not found" when /etc/rc sources rc.conf. The full
# list combines configure_system's defaults (linux linux64 cuse fusefs
# hgame) with the live-mode additions.
{
    echo 'root_rw_mount="NO"'
    echo 'sendmail_enable="NO"'
    echo 'sendmail_submit_enable="NO"'
    echo 'sendmail_outbound_enable="NO"'
    echo 'sendmail_msp_queue_enable="NO"'
    echo 'linux_enable="YES"'
    echo 'dbus_enable="YES"'
    echo 'kld_list="linux linux64 cuse fusefs hgame ig4 iicbus iichid utouch asmc if_urndis if_cdce if_ipheth"'
    echo 'allscreens_kbdflags="-b quiet.off"'
} >> /sysroot/etc/rc.conf

# === rcorder REQUIRE/BEFORE surgery ===
# Want: zfs -> ldconfig -> dbus/initgfx/localize -> slim -> everything else
sed -i '' -e 's|# REQUIRE: .*|# REQUIRE: zfs|g' /sysroot/etc/rc.d/ldconfig
sed -i '' -e 's|# REQUIRE: .*|# REQUIRE: ldconfig|g' /sysroot/usr/local/etc/rc.d/dbus 2>/dev/null || true
sed -i '' -e 's|# REQUIRE: .*|# REQUIRE: ldconfig|g' /sysroot/etc/rc.d/initgfx 2>/dev/null || true
sed -i '' -e 's|# REQUIRE: .*|# REQUIRE: localize dbus initgfx\n# BEFORE: |g' /sysroot/usr/local/etc/rc.d/slim 2>/dev/null || true

# Lower initgfx 3 second sleep between Xorg runs
sed -i '' -e 's|\&\& __wait 3|\&\& __wait 1|g' /sysroot/etc/rc.d/initgfx 2>/dev/null || true

# === Disable console beeps without rc.conf editing ===
kbdcontrol -b quiet.off 2>/dev/null || true

# === Monkey patch from EFI variable ===
# /rescue lacks grep, so the EFI-variable detection only runs if
# /usr/bin/grep exists (it doesn't, pre-chroot). Fall through to the
# kenv-based check, which is the path actually exercised in CI.
MONKEY_PATCH=NO
if command -v grep >/dev/null 2>&1; then
    EFIVAR=$(efivar -Al 2>/dev/null | grep -e "[0-9a-z]*-[0-9a-z]*-[0-9a-z]*-[0-9a-z]*-[0-9a-z]*-MonkeyPatch$" 2>/dev/null)
    if [ -n "${EFIVAR}" ] ; then
      echo "[init.sh] Monkey patch requested by EFI variable"
      MONKEY_PATCH=YES
    fi
fi

if [ "$(kenv monkey_patch 2>/dev/null)" != "" ] ; then
  echo "[init.sh] Monkey patch requested by kenv"
  MONKEY_PATCH=YES
fi

if [ "$MONKEY_PATCH" = "YES" ] ; then
  echo ""
  echo "Monkey patch requested."
  echo "Looking for a file named monkeypatch.sh on a msdosfs geom with the label MONKEYPATCH"
  echo ""
  echo "Waiting for /dev/msdosfs/MONKEYPATCH to appear..."
  while : ; do
    [ -e "/dev/msdosfs/MONKEYPATCH" ] && echo "found /dev/msdosfs/MONKEYPATCH" && sleep 2 && break
    sleep 2
  done
  mkdir -p /sysroot/media/MONKEYPATCH
  mount -t msdosfs "/dev/msdosfs/MONKEYPATCH" /sysroot/media/MONKEYPATCH
  if [ -e "/sysroot/media/MONKEYPATCH/monkeypatch.sh" ] ; then
    echo "Applying monkey patch..." > /dev/console
    chroot /sysroot sh /media/MONKEYPATCH/monkeypatch.sh > /dev/console
  else
    echo "/monkeypatch.sh missing" > /dev/console
  fi
  umount -f /sysroot/media/MONKEYPATCH
  echo "Done" > /dev/console
fi

# === Pre-chroot cleanup ===
export TERM=xterm
# /rescue lacks clear; emit ANSI clear directly. Suppress on serial
# where the escape just looks like garbage.
printf '\033[2J\033[H' >/dev/console 2>/dev/null || true
conscontrol mute on >/dev/null 2>&1 || true

# === Tell init to chroot into /sysroot after we exit ===
# init.c reads init_chroot kenv at line 333, AFTER init_script (line
# 326-331) has run. Setting init_chroot here is what makes the chroot
# happen.
echo "[init.sh] setting init_chroot=/sysroot"
kenv init_chroot=/sysroot

# Unset init_script so init doesn't try to re-run us after the chroot.
kenv -u init_script 2>/dev/null || true
kenv -u init_shell  2>/dev/null || true

echo "[init.sh] handing off to /sbin/init for chroot+multi-user"
exit 0

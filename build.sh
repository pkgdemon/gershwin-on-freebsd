#!/usr/bin/env sh
#
#
# Gershwin-on-FreeBSD Build Script
#
# This script builds the Gershwin Desktop live system based on FreeBSD.
# It handles workspace preparation, base system installation, desktop
# software integration, and ISO image generation.
#
# Requirements: FreeBSD system with pkg, makefs, mkuzip, etc.

set -e -u

# --- Configuration ---
LABEL="FREEBSD"
IMAGE_NAME_PREFIX="gershwin-on-freebsd"
WORKDIR="/usr/local/freebsd-build"

# Target Environment (Decoupled from Host)
TARGET_VERSION="${TARGET_VERSION:-14}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"
# Map TARGET_ARCH to filename-friendly architecture string
case "${TARGET_ARCH}" in
    amd64) ARCH_STR="x86_64" ;;
    aarch64) ARCH_STR="aarch64" ;;
    *) ARCH_STR="${TARGET_ARCH}" ;;
esac
TARGET_ABI="FreeBSD:${TARGET_VERSION}:${TARGET_ARCH}"
# Branch and OSVERSION mapping
case "${TARGET_VERSION}" in
    15)
        TARGET_OSVERSION="1500028"
        REPO_BRANCH="latest" # release_1 will contain XLibre; base_quarterly is missing?
        ;;
    16)
        TARGET_OSVERSION="1600000"
        REPO_BRANCH="latest"
        ;;
    *)
        TARGET_OSVERSION="${TARGET_VERSION}00000"
        REPO_BRANCH="${REPO_BRANCH:-stable}"
        ;;
esac

RELEASE_DIR="${WORKDIR}/release"
ISO_DIR="${WORKDIR}/iso"
CD_ROOT="${WORKDIR}/cd_root"
PKGS_STORAGE="${WORKDIR}/packages"
LIVE_USER="freebsd"
PKG_CONF_NAME="FreeBSD"

# Paths to resources
CWD="$(pwd)"
RESOURCE_DIR="${CWD}/resources"
PKG_LIST_DIR="${RESOURCE_DIR}/packages"
CONFIG_DIR="${WORKDIR}/config/repos"
SCRIPTS_DIR="${RESOURCE_DIR}/scripts"
OVERLAYS_DIR="${RESOURCE_DIR}/overlays"

# --- Environment Fixes ---
export ABI="${TARGET_ABI}"
export OSVERSION="${TARGET_OSVERSION}"
export IGNORE_OSVERSION="yes"
export ASSUME_ALWAYS_YES="yes"

# Unified PKG command
pkg_cmd() {
    env ABI="${ABI}" OSVERSION="${OSVERSION}" IGNORE_OSVERSION="yes" ASSUME_ALWAYS_YES="yes" \
        pkg -R "${CONFIG_DIR}" "$@"
}

# --- Lifecycle Management ---
cleanup() {
    log "Cleaning up mounts..."
    [ -d "${RELEASE_DIR}/dev" ] && umount "${RELEASE_DIR}/dev" 2>/dev/null || true
    [ -d "${RELEASE_DIR}/proc" ] && umount "${RELEASE_DIR}/proc" 2>/dev/null || true
    [ -d "${RELEASE_DIR}/sys" ] && umount "${RELEASE_DIR}/sys" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log_env() {
    log "Environment: ABI=${ABI}, OSVERSION=${OSVERSION}, REPO_BRANCH=${REPO_BRANCH}"
}

# --- Logging ---
log() {
    printf "\033[1;32m%s [BUILD]\033[0m %s\n" "$(date '+%H:%M:%S')" "$*"
}

error() {
    printf "\033[1;31m%s [ERROR]\033[0m %s\n" "$(date '+%H:%M:%S')" "$*" >&2
    exit 1
}

# --- Initialization ---
[ "$(id -u)" -eq 0 ] || error "This script must be run as root."

setup_workspace() {
    log "Preparing workspace at ${WORKDIR}..."

    # Cleanup previous builds
    for dir in "${RELEASE_DIR}" "${CD_ROOT}"; do
        if [ -d "$dir" ]; then
            chflags -R noschg "$dir" >/dev/null 2>&1 || true
            umount -f "${dir}/var/cache/pkg" >/dev/null 2>&1 || true
            umount -f "${dir}/dev" >/dev/null 2>&1 || true
            rm -rf "$dir"
        fi
    done

    mkdir -p "${WORKDIR}" "${ISO_DIR}" "${PKGS_STORAGE}" "${RELEASE_DIR}" "${CD_ROOT}" "${CONFIG_DIR}"

    # Generate Repository Configuration
    log "Generating repository configuration for ${TARGET_ABI} on ${REPO_BRANCH} branch..."
    cat > "${CONFIG_DIR}/FreeBSD.conf" <<EOF
FreeBSD_base: {
  url: "https://pkg.freebsd.org/${TARGET_ABI}/base_${REPO_BRANCH}",
  enabled: yes
}

FreeBSD_pkg: {
  url: "https://pkg.freebsd.org/${TARGET_ABI}/${REPO_BRANCH}",
  enabled: yes
}

FreeBSD_kmods: {
  url: "https://pkg.freebsd.org/${TARGET_ABI}/kmods_${REPO_BRANCH}",
  enabled: yes,
  priority: 10
}
EOF
}

# --- Build Stages ---

install_base_system() {
    log "Installing base system packages..."
    mkdir -p "${RELEASE_DIR}/etc" "${RELEASE_DIR}/var/cache/pkg" "${RELEASE_DIR}/var/db/pkg"
    cp /etc/resolv.conf "${RELEASE_DIR}/etc/resolv.conf"
    # Create missing bzip2.pc file required by freetype2
    mkdir -p "${RELEASE_DIR}/usr/local/libdata/pkgconfig"
    cat > "${RELEASE_DIR}/usr/local/libdata/pkgconfig/bzip2.pc" << 'EOF'
prefix=/usr/local
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: bzip2
Description: bzip2 compression library
Version: 1.0.8
Libs: -L${libdir} -lbz2
Cflags: -I${includedir}
EOF
    
    mount_nullfs "${PKGS_STORAGE}" "${RELEASE_DIR}/var/cache/pkg"
    
    pkg_cmd -r "${RELEASE_DIR}" update -f
    pkg_cmd -r "${RELEASE_DIR}" clean -a -y || true
    
    # Filter base packages to only those available in the repo
    log "Filtering base packages..."
    pkg_cmd -r "${RELEASE_DIR}" rquery -r FreeBSD_base "%n" > "${WORKDIR}/available_base.txt"
    grep -Fxf "${WORKDIR}/available_base.txt" "${PKG_LIST_DIR}/base" > "${WORKDIR}/filtered_base.txt" || true
    
    # Use xargs to avoid "Argument list too long" errors
    log "Installing base packages..."
    if [ -s "${WORKDIR}/filtered_base.txt" ]; then
        cat "${WORKDIR}/filtered_base.txt" | xargs env ABI="${ABI}" OSVERSION="${OSVERSION}" IGNORE_OSVERSION="yes" ASSUME_ALWAYS_YES="yes" pkg -R "${CONFIG_DIR}" -r "${RELEASE_DIR}" install -y -r FreeBSD_base
    else
        log "Warning: No base packages found to install!"
    fi
    
    log "Setting vital-base packages..."
    pkg_cmd -r "${RELEASE_DIR}" query "%n" > "${WORKDIR}/installed_pkg.txt"
    grep -Fxf "${WORKDIR}/installed_pkg.txt" "${PKG_LIST_DIR}/vital-base" > "${WORKDIR}/filtered_vital_base.txt" || true
    if [ -s "${WORKDIR}/filtered_vital_base.txt" ]; then
        cat "${WORKDIR}/filtered_vital_base.txt" | xargs env ABI="${ABI}" OSVERSION="${OSVERSION}" IGNORE_OSVERSION="yes" ASSUME_ALWAYS_YES="yes" pkg -R "${CONFIG_DIR}" -r "${RELEASE_DIR}" set -y -v 1
    fi
    
    umount "${RELEASE_DIR}/var/cache/pkg"
    rm "${RELEASE_DIR}/etc/resolv.conf"
    touch "${RELEASE_DIR}/etc/fstab"
    mkdir -p "${RELEASE_DIR}/cdrom" "${RELEASE_DIR}/mnt" "${RELEASE_DIR}/media"
}

install_gershwin_software() {
    log "Installing Gershwin software environment..."
    cp /etc/resolv.conf "${RELEASE_DIR}/etc/resolv.conf"
    mkdir -p "${RELEASE_DIR}/var/cache/pkg"
    mount_nullfs "${PKGS_STORAGE}" "${RELEASE_DIR}/var/cache/pkg"
    mount -t devfs devfs "${RELEASE_DIR}/dev"
    mkdir -p "${RELEASE_DIR}/proc"
    mount -t procfs proc "${RELEASE_DIR}/proc"

    pkg_cmd -r "${RELEASE_DIR}" update -f
    pkg_cmd -r "${RELEASE_DIR}" clean -a -y || true
    
    # Filter Gershwin and driver packages
    log "Filtering desktop packages..."
    pkg_cmd -r "${RELEASE_DIR}" rquery -r FreeBSD_pkg "%n" > "${WORKDIR}/available_pkg.txt"
    cat "${PKG_LIST_DIR}/gershwin" "${PKG_LIST_DIR}/drivers" | grep -Fxf "${WORKDIR}/available_pkg.txt" > "${WORKDIR}/filtered_pkg.txt" || true

    # Install main packages from the Pkg repo
    log "Installing Gershwin and driver packages..."
    if [ -s "${WORKDIR}/filtered_pkg.txt" ]; then
        cat "${WORKDIR}/filtered_pkg.txt" | xargs env ABI="${ABI}" OSVERSION="${OSVERSION}" IGNORE_OSVERSION="yes" ASSUME_ALWAYS_YES="yes" pkg -R "${CONFIG_DIR}" -r "${RELEASE_DIR}" install -y
    else
        log "Warning: No desktop packages found to install!"
    fi
        
    # Set vital packages
    log "Setting vital-gershwin packages..."
    pkg_cmd -r "${RELEASE_DIR}" query "%n" > "${WORKDIR}/installed_pkg_gershwin.txt"
    grep -Fxf "${WORKDIR}/installed_pkg_gershwin.txt" "${PKG_LIST_DIR}/vital-gershwin" > "${WORKDIR}/filtered_vital_gershwin.txt" || true
    if [ -s "${WORKDIR}/filtered_vital_gershwin.txt" ]; then
        cat "${WORKDIR}/filtered_vital_gershwin.txt" | xargs env ABI="${ABI}" OSVERSION="${OSVERSION}" IGNORE_OSVERSION="yes" ASSUME_ALWAYS_YES="yes" pkg -R "${CONFIG_DIR}" -r "${RELEASE_DIR}" set -y -v 1
    fi
    
    # Cleanup
    rm "${RELEASE_DIR}/etc/resolv.conf"
    umount "${RELEASE_DIR}/var/cache/pkg"
    umount "${RELEASE_DIR}/proc" || true
    umount "${RELEASE_DIR}/dev"
}

configure_system() {
    log "Applying system configurations..."

    # Services
    cat <<EFS | xargs -n1 chroot "${RELEASE_DIR}" sysrc
hostname="gershwin"
zfs_enable="YES"
defaultroute_delay="0"
network_interfaces="auto"
ifconfig_DEFAULT="DHCP"
synchronous_dhclient="NO"
dhclient_flags="-n"
ipv6_activate_all_interfaces="YES"
ipv6_cpe_wanif="auto"
rtsold_enable="YES"
background_dhclient="YES"
ntpd_sync_on_start="YES"
ntpd_flags="-g"
kld_list="linux linux64 cuse fusefs hgame"
linux_enable="YES"
devfs_enable="YES"
devfs_system_ruleset="system"
moused_enable="YES"
dbus_enable="YES"
webcamd_enable="YES"
cupsd_enable="YES"
avahi_daemon_enable="YES"
avahi_dnsconfd_enable="YES"
ntpd_enable="YES"
ntpd_sync_on_start="YES"
clear_tmp_enable="YES"
dsbdriverd_enable="YES"
initgfx_enable="YES"
initgfx_menu="NO"
smartd_enable="YES"
EFS

    # Initialize Directory Services and create live user
    log "Initializing Directory Services..."
    chroot "${RELEASE_DIR}" sh -c ". /System/Library/Makefiles/GNUstep.sh && dscli init"

    # Sudoers
    sed -i "" -e 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/g' "${RELEASE_DIR}/usr/local/etc/sudoers"

    # System Patches
    [ -f "${CONFIG_DIR}/devfs.rules.extra" ] && cat "${CONFIG_DIR}/devfs.rules.extra" >> "${RELEASE_DIR}/etc/devfs.rules"
    [ -f "${CONFIG_DIR}/fstab.extra" ] && cat "${CONFIG_DIR}/fstab.extra" >> "${RELEASE_DIR}/etc/fstab"
    mkdir -p "${RELEASE_DIR}/compat/linux/dev/shm" "${RELEASE_DIR}/compat/linux/sys"

    # Branding
    mkdir -p "${RELEASE_DIR}/usr/local/share/freebsd"
    echo "gershwin" > "${RELEASE_DIR}/usr/local/share/freebsd/desktop"

    # Update ldconfig cache. /System/Library/Libraries holds libdispatch,
    # libobjc, libgnustep-base, libgnustep-corebase from gershwin-developer's
    # GNUstep install — daemons like dshelper link against libdispatch and
    # need rtld to find it via the hints DB. /usr/local/libdata/ldconfig/
    # entry is for /etc/rc.d/ldconfig if rc ever runs (it doesn't under
    # launchd PID 1, but the file is harmless and future-proof). The
    # build-time `ldconfig -m` primes /var/run/ld-elf.so.hints in the uzip;
    # under launchd that file isn't overwritten at boot, so the hints
    # persist into the live system.
    mkdir -p "${RELEASE_DIR}/usr/local/libdata/ldconfig"
    echo "/System/Library/Libraries" \
        > "${RELEASE_DIR}/usr/local/libdata/ldconfig/freebsd-launchd"
    chroot "${RELEASE_DIR}" ldconfig -m /usr/local/lib /System/Library/Libraries
}

build_gershwin_components() {
    log "Building Gershwin components from source..."
    git clone --branch feat/libs-corebase --depth 1 https://github.com/gershwin-desktop/gershwin-developer "${RELEASE_DIR}/Developer"

    cp /etc/resolv.conf "${RELEASE_DIR}/etc/resolv.conf"

    # Pre-build hack for compatibility
    chroot "${RELEASE_DIR}" sh -c "cd /usr/local/lib && rm -f libbfd-2.43.so libbfd-2.44.so && ln -sf libbfd.so libbfd-2.43.so && ln -sf libbfd.so libbfd-2.44.so || true"
    chroot "${RELEASE_DIR}" ldconfig -m /usr/local/lib

    # Make sure we have devfs and procfs for the build
    mount -t devfs devfs "${RELEASE_DIR}/dev" 2>/dev/null || true
    mkdir -p "${RELEASE_DIR}/proc"
    mount -t procfs proc "${RELEASE_DIR}/proc" 2>/dev/null || true

    # Build inside chroot
    chroot "${RELEASE_DIR}" sh -c "/Developer/Library/Scripts/Bootstrap.sh"
    chroot "${RELEASE_DIR}" sh -c "PINNED=1 /Developer/Library/Scripts/Checkout.sh"
    chroot "${RELEASE_DIR}" sh -c "cd /Developer && make install"

    # Cleanup mounts
    umount "${RELEASE_DIR}/proc" || true
    umount "${RELEASE_DIR}/dev" || true

    rm -f "${RELEASE_DIR}/etc/resolv.conf"
}

build_launchd() {
    log "Building freebsd-launchd from source..."

    # Host-side git clone writing into the chroot's Sources tree —
    # mirrors gershwin's existing build.sh:281 pattern (clone destination
    # is inside RELEASE_DIR; git itself runs on the host). Lands as a
    # sibling to gershwin-developer's Library/Sources/ trees.
    git clone --depth 1 https://github.com/pkgdemon/freebsd-launchd \
        "${RELEASE_DIR}/Developer/Library/Sources/freebsd-launchd"

    cp /etc/resolv.conf "${RELEASE_DIR}/etc/resolv.conf"
    mount -t devfs devfs "${RELEASE_DIR}/dev" 2>/dev/null || true

    # make-launchd.sh checks for /System/Library/Libraries/{libdispatch,
    # libobjc,libgnustep-base,libgnustep-corebase}.so before building
    # (which build_gershwin_components just installed) and runs gmake
    # against the launchd src/ tree. Result: /sbin/launchd + /sbin/launchctl.
    chroot "${RELEASE_DIR}" sh -c "
        cd /Developer/Library/Sources/freebsd-launchd &&
        ./make-launchd.sh
    "

    # Install the getty wrapper from freebsd-launchd's overlays (the
    # existing shell-wrapper exception, referenced by org.freebsd.getty.*
    # plists). make-launchd.sh installs only the launchd binaries; the
    # overlay tree is copied separately.
    install -d "${RELEASE_DIR}/usr/libexec"
    install -m 755 \
        "${RELEASE_DIR}/Developer/Library/Sources/freebsd-launchd/overlays/usr/libexec/launchd-getty-wrapper" \
        "${RELEASE_DIR}/usr/libexec/launchd-getty-wrapper"

    # Install bedrock LaunchDaemon plists from freebsd-launchd's overlays.
    # Skips:
    # - kmodloader.plist: Phase 2 doesn't build the kmodloader binary
    #   (Phase 3 work). Its plist would respawn-loop forever.
    # - getty.console.plist + getty.vty0.plist: gershwin uses LoginWindow
    #   as the login UI. A text-mode getty is redundant and was looping
    #   on login_tty failures because launchd's session controls the
    #   tty. We don't ship them at all rather than fight the conflict.
    install -d "${RELEASE_DIR}/System/Library/LaunchDaemons"
    for plist in "${RELEASE_DIR}/Developer/Library/Sources/freebsd-launchd/overlays/System/Library/LaunchDaemons/"*.plist; do
        case "$(basename "$plist")" in
            org.freebsd.kmodloader.plist)    continue ;;
            org.freebsd.getty.console.plist) continue ;;
            org.freebsd.getty.vty0.plist)    continue ;;
        esac
        install -m 644 "$plist" "${RELEASE_DIR}/System/Library/LaunchDaemons/"
    done

    # Install gershwin-specific LaunchDaemon plists (gdomap, dshelper,
    # loginwindow) from this repo's overlays/System/.
    cp -R "${OVERLAYS_DIR}/System/." "${RELEASE_DIR}/System/"

    umount "${RELEASE_DIR}/dev" 2>/dev/null || true
    rm -f "${RELEASE_DIR}/etc/resolv.conf"
}

downsize_system() {
    log "Downsizing system (removing heavy build artifacts)..."
    # Reduce LLVM size
    if [ -d "${RELEASE_DIR}/usr/local/llvm19/lib/" ]; then
        mkdir -p "${RELEASE_DIR}/tmp_llvm"
        find "${RELEASE_DIR}/usr/local/llvm19/lib/" -name "libLLVM*.so*" -exec mv {} "${RELEASE_DIR}/tmp_llvm/" \;
        rm -rf "${RELEASE_DIR}/usr/local/llvm19"
        mkdir -p "${RELEASE_DIR}/usr/local/llvm19/lib/"
        mv "${RELEASE_DIR}/tmp_llvm/"* "${RELEASE_DIR}/usr/local/llvm19/lib/"
        rmdir "${RELEASE_DIR}/tmp_llvm"
    fi
}

prepare_boot_env() {
    log "Preparing boot environment (unionfs init_chroot model)..."

    # Stage minimal /boot on cd9660 file-by-file, mirroring the
    # freebsd-launchd pattern (build.sh:481-541). Three benefits over
    # the previous "tar everything from RELEASE_DIR/boot, then prune"
    # approach:
    #   1. /boot/firmware never gets created on cd9660 as a real
    #      directory, so the symlink to /sysroot/boot/firmware lands
    #      cleanly via plain `ln -s`. The previous tar-pipe pulled in
    #      base.txz's /boot/firmware/ tree as a directory; `ln -sf`
    #      against an existing directory creates a useless nested
    #      symlink (${CD_ROOT}/boot/firmware/firmware), invisible to
    #      kernel-namei's lookup of /boot/firmware/<file>. Hence:
    #      AMD Renoir / iwlwifi firmware loads still fail.
    #   2. cd9660 is much smaller. base.txz's /boot is hundreds of MB
    #      across base firmware, GENERIC's ~80 .ko modules, debug
    #      symbols, etc. Only the bootloader stage and a handful of
    #      preload modules need to live outside rootfs.uzip; the rest
    #      is reached via unionfs after pivot.
    #   3. Whitelist is auditable. "Copy everything then delete most of
    #      it" obscured what actually had to be on cd9660 vs. what was
    #      incidental. This makes the contract explicit.

    mkdir -p "${CD_ROOT}/boot/kernel"

    # Bootloader binaries + lua scripts + fonts. Conditional copies —
    # not all entries exist on every release/arch. cdboot/isoboot/pmbr
    # = legacy BIOS chains; loader_lua / loader_lua.efi = current
    # FreeBSD primary loader; loader_simp{,.efi} = simplified fallback;
    # boot1.efi / gptboot = stage-1 EFI / GPT loaders; defaults/ holds
    # the system loader.conf the project's overlay loader.conf
    # `include`s; device.hints feeds the kernel's hardware probe; lua/
    # is the loader's Lua tree; fonts/ powers the boot menu typography.
    for f in cdboot loader loader.efi loader_lua loader_lua.efi \
             loader_simp loader_simp.efi pmbr isoboot boot1.efi \
             gptboot defaults device.hints lua fonts; do
        if [ -e "${RELEASE_DIR}/boot/$f" ]; then
            cp -aR "${RELEASE_DIR}/boot/$f" "${CD_ROOT}/boot/"
        fi
    done

    # Kernel binary, gzipped. The loader's gzipfs layer detects the .gz
    # extension and decompresses transparently on read (same pattern
    # mfsBSD uses).
    gzip -9c "${RELEASE_DIR}/boot/kernel/kernel" \
        > "${CD_ROOT}/boot/kernel/kernel.gz"
    ls -lh "${CD_ROOT}/boot/kernel/kernel.gz" \
           "${RELEASE_DIR}/boot/kernel/kernel"

    # Modules needed BEFORE /init.sh's unionfs cascade — i.e. before
    # the running kernel can reach into rootfs.uzip. Everything else
    # (~80 GENERIC .ko modules) lives only in rootfs.uzip and gets
    # kldloaded post-pivot, either by loader.conf preloads against the
    # uzip-mounted /boot/kernel/, or by kmodloader at runtime.
    #
    #   geom_uzip   — required to mdconfig-mount rootfs.uzip
    #   unionfs     — required for the cascade in init.sh
    #   xz          — loader.conf may preload xz-compressed modules
    #   cryptodev   — preserved from previous configuration; loaded
    #                 early on systems using GELI-encrypted partitions
    #                 (irrelevant on the live ISO, but harmless)
    #   firewire    — preserved from previous configuration; legacy
    #                 IEEE-1394 storage edge case
    #
    # Each gets gzipped after copy: same loader gzipfs trick as the
    # kernel.
    BOOT_MODULES="geom_uzip.ko unionfs.ko xz.ko cryptodev.ko firewire.ko"
    for m in ${BOOT_MODULES}; do
        if [ -f "${RELEASE_DIR}/boot/kernel/$m" ]; then
            cp "${RELEASE_DIR}/boot/kernel/$m" "${CD_ROOT}/boot/kernel/"
            gzip -f "${CD_ROOT}/boot/kernel/$m"
        fi
    done

    # Mountpoints needed by /init.sh's unionfs cascade. /sysroot is the
    # merge target (uzip lower + tmpfs upper); /upper is the writable
    # layer; /dev gets the cd9660-context devfs before we mount
    # /sysroot/dev separately. /etc exists for mkisoimages.sh, which
    # writes a transient /etc/fstab during ISO mastering and removes it
    # immediately — the dir needs to exist or the redirect fails.
    mkdir -p "${CD_ROOT}/sysroot" "${CD_ROOT}/upper" \
             "${CD_ROOT}/dev" "${CD_ROOT}/etc"

    cp "${RELEASE_DIR}/COPYRIGHT" "${CD_ROOT}/"

    # Drop /init.sh at the cdroot top-level. /sbin/init reads init_script
    # kenv (set in /boot/loader.conf) and forks a child to run it.
    chmod +x "${OVERLAYS_DIR}/init.sh"
    cp "${OVERLAYS_DIR}/init.sh" "${CD_ROOT}/init.sh"

    # Boot overlay (loader.conf, lua/local.lua, loader.mute.d). Layered
    # ON TOP of the bootloader files we just staged from RELEASE_DIR —
    # cp -R merges into the existing tree, so the overlay's loader.conf
    # replaces the base one while shared subtrees (defaults/, lua/) get
    # overlay files added without losing the originals.
    cp -R "${OVERLAYS_DIR}/boot" "${CD_ROOT}"
    cat "${CD_ROOT}/boot/loader.conf"

    # /rescue: needed on cd9660 because init.sh's shebang is /rescue/sh
    # and the kernel exec's /rescue/init (since /sbin/init isn't on the
    # cd9660). Hardlink-deduped with fdupes; Rock Ridge preserves links
    # across cd9660. Subshell for the cd so we don't pollute the
    # function's working directory.
    ( cd "${RELEASE_DIR}" && tar -cf - rescue ) | tar -xf - -C "${CD_ROOT}"
    fdupes -r -S -N "${CD_ROOT}/rescue" || true
    ls -lh "${CD_ROOT}/rescue"

    # Comment out splash so we get the non-color kernel picture instead
    # of a color one that doesn't match our color scheme.
    sed -i '' -e 's|^splash|# splash|g' "${CD_ROOT}/boot/loader.conf"

    # Must not try to load tmpfs module in FreeBSD 13 and later — the
    # in-kernel tmpfs is preferred and a kld attempt will fail. We
    # never copy tmpfs.ko into cdroot (it's not in BOOT_MODULES), so
    # only the loader.conf comment-out is needed; no rm necessary.
    sed -i '' -e 's|^tmpfs_load|# load_tmpfs_load|g' "${CD_ROOT}/boot/loader.conf"

    # /boot/firmware on the cd9660 → symlink to /sysroot/boot/firmware
    # (where the unionfs mounts the rootfs.uzip layer at boot, with all
    # pkg-installed firmware files inside).
    #
    # Why: kernel-context vn_open in subr_firmware.c's try_binary_file()
    # does namei against the kernel's root namespace, which is the
    # cd9660 mount — NOT the chroot the userspace processes see. Files
    # visible at /boot/firmware/ in chroot view are invisible to kernel
    # firmware loading. Result without this symlink: iwlwifi/i915kms/
    # amdgpu attach but firmware-load fails with "File size way too
    # small!" or "could not load binary firmware …", and on AMD Renoir
    # specifically drm-kmod's fini_hw NULL-derefs in
    # unregister_fictitious_range → kernel panic during kldload amdgpu.
    #
    # The symlink turns kernel-namei's lookup of /boot/firmware/<file>
    # into a follow-through-mount-point chain:
    #   1. cd9660:/boot/firmware → symlink → /sysroot/boot/firmware
    #   2. cd9660:/sysroot is the unionfs mount point
    #   3. namei traverses into the unionfs view
    #   4. Finds the file in the rootfs.uzip layer
    # Costs ~0 bytes on the cd9660. Rock Ridge on cd9660 (already
    # enabled via mkisoimages.sh) preserves symlinks correctly.
    #
    # Plain `ln -s` (no -f) is sufficient now that we build cdroot/boot
    # file-by-file: /boot/firmware is never created as a directory in
    # the first place, so there's nothing to overwrite.
    ln -s /sysroot/boot/firmware "${CD_ROOT}/boot/firmware"
    ls -la "${CD_ROOT}/boot/firmware" || true

    # https://github.com/freebsd/freebsd-src/blob/5bffa1d2069a05c8346eb34e17a39085fe0bf09b/sbin/init/init.c#L1061
    chmod 755 "${CD_ROOT}/init.sh"
}

generate_iso() {
    log "Creating live image (uzip)..."
    ( cd "${RELEASE_DIR}" ; makefs -b 75% -f 75% -R 262144 "${CD_ROOT}/rootfs.ufs" . )
    # /rootfs.uzip lives at the cdroot top-level (not /boot/rootfs.uzip) —
    # /init.sh mdconfig-mounts it from /rootfs.uzip directly.
    mkuzip -A zstd -C 12 -d -o "${CD_ROOT}/rootfs.uzip" "${CD_ROOT}/rootfs.ufs"
    rm -f "${CD_ROOT}/rootfs.ufs"

    log "Generating final ISO image..."
    ISO_PATH="${ISO_DIR}/${IMAGE_NAME_PREFIX}-$(date +%Y%m%d%H%M%S)-${ARCH_STR}.iso"
    # Provide a way to know from the booted ISO what ISO it is
    echo "${IMAGE_NAME_PREFIX}-$(date +%Y%m%d%H%M%S)-${ARCH_STR}.iso" >> "${CD_ROOT}/.iso"

    # Canonical path: run the upstream mkisoimages.sh from its directory so it can
    # reliably source install-boot.sh and produce a hybrid EFI/BIOS image.
    if [ ! -f "${CWD}/resources/scripts/mkisoimages.sh" ]; then
        error "Required script missing: ${CWD}/resources/scripts/mkisoimages.sh"
    fi

    log "Creating ISO using mkisoimages.sh (canonical single path — EFI and BIOS hybrid)..."
    ( cd "${CWD}/resources/scripts" && sh ./mkisoimages.sh -b "${LABEL}" "${ISO_PATH}" "${CD_ROOT}" )

    
    log "ISO created at: ${ISO_PATH}"
    if command -v sha256 >/dev/null; then
        sha256 -q "${ISO_PATH}" > "${ISO_PATH}.sha256"
    elif command -v sha256sum >/dev/null; then
        sha256sum "${ISO_PATH}" > "${ISO_PATH}.sha256"
    fi
}

split()
{
  # units -o "%0.f" -t "2 gigabytes" "bytes"
  THRESHOLD_BYTES=2147483647
  # THRESHOLD_BYTES=1999999999
  ISO_SIZE=$(stat -f%z "${ISO_PATH}")
  if [ $ISO_SIZE -gt $THRESHOLD_BYTES ] ; then
    echo "Size exceeds GitHub Releases file size limit; splitting the ISO"
    sudo split -d -b "$THRESHOLD_BYTES" -a 1 "${ISO_PATH}" "${ISO_PATH}.part"
    echo "Split the ISO, deleting the original"
    rm "${ISO_PATH}"
    ls -l "${ISO_PATH}"*
  fi
}

# --- Main Execution ---
log_env
setup_workspace
install_base_system
install_gershwin_software
build_gershwin_components
build_launchd
configure_system
downsize_system
prepare_boot_env
generate_iso
if [ -n "${CIRRUS_CI:-}" ] ; then
  # On Cirrus CI we want to upload to GitHub Releases which has a 2 GB file size limit,
  # hence we need to split the ISO there if it is too large
  split
fi

log "Build complete!"

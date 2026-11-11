#!/usr/bin/env bash
# Patch vendor.img of android-system-generic-x86-64 (lineage-24.0) to force the
# DRM-FB composer APEX by injecting `ro.boot.hwc_apex=2` into /vendor/build.prop.
#
# Fixes github.com/IzumiSenaSora/Generic_X86_64/issues/3:
# SurfaceFlinger SIGABRT "No matching frame rate modes for primary range even
# after ignoring the render range" when using drm_hwcomposer_upstream on Intel
# RPL-U (8086:a7a1). ro.boot.hwc_apex=2 => HwcApex::DrmFb =>
# com.android.hardware.graphics.composer.drmfb (the same working composer that
# the `nomodeset` boot path picks via sysfb).
#
# Usage:
#   sudo ./patch_vendor_hwc.sh [path/to/vendor.img]
#   - with an argument: patch that image (backup written alongside as .orig)
#   - without:          search mounted/partition devices for the installed
#                       android_dir (imgs/vendor.img) and patch it
#
# Requires: erofs tools (mkfs.erofs/fsck.erofs/dump.erofs), root, lz4.
set -euo pipefail

EROFSDIR_AT_DEFAULTS=(
    /home/iris/android17/extracted/erofs-inst/bin
)
[ -n "${EROFSDIR:-}" ] || EROFSDIR=$(dirname "$(readlink -f "$0")")/extracted/erofs-inst/bin
for d in "$EROFSDIR" "${EROFSDIR_AT_DEFAULTS[@]}" /usr/local/bin; do
    if [ -x "$d/mkfs.erofs" ]; then EROFSBIN="$d"; break; fi
done
[ -n "${EROFSBIN:-}" ] || { echo "ERROR: mkfs.erofs not found (set EROFSDIR)" >&2; exit 1; }

OVERRIDE_BLOCK='# OVERRIDE (issue #3): force drmfb-composer3
ro.boot.hwc_apex=2'

# REAL root-cause fix (2026-11-08): the panel reports 60.003117 Hz; with frame rate
# override disabled (device tree vendor.prop explicitly sets `false`) SF's RefreshRateSelector
# rejects the only mode (C++ epsilon 0.001 Hz vs DMS Java tolerance 0.01 Hz) and LOG_ALWAYS_FATALs
# -> bootloop. Enabling the override restores the AOSP default and boots. See issue3-root-cause.md.
FIX_PROP='ro.surface_flinger.enable_frame_rate_override'

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run me as root (need to preserve image owner/permissions)"; }

find_installed_vendor_img() {
    local part mnt cand
    # mounted already?
    for cand in /media/*/*/imgs/vendor.img /media/*/imgs/vendor.img; do
        [ -f "$cand" ] && { echo "$cand"; return 0; }
    done
    while read -r part; do
        case "$part" in */[0-9]|/dev/*) ;; *) continue ;; esac
        case "$(lsblk -no TYPE "$part")" in part|partition) ;; *) continue ;; esac
        mnt=$(mktemp -d /tmp/vfind.XXXXXX)
        if mount -o ro "$part" "$mnt" 2>/dev/null; then
            for f in "$mnt/imgs/vendor.img" "$mnt/android-system-generic-x86-64/imgs/vendor.img" \
                     "$mnt/vendor.img"; do
                if [ -f "$f" ]; then echo "$f"; umount "$mnt"; rmdir "$mnt"; return 0; fi
            done
            umount "$mnt"
        fi
        rmdir "$mnt"
    done < <(lsblk -rno NAME,TYPE,FSTYPE -e 7 | awk '$2=="part" && $3!="" {print "/dev/"$1}')
    return 1
}

mkfs_time_of() { # original image build time, to reproduce image metadata
    $EROFSBIN/dump.erofs -s "$1" 2>/dev/null | awk '/Filesystem created/ {ts=$0}'
}

patch_image() {
    local src="$1" work origts
    need_root
    [ -f "$src" ] || die "no such file: $src"
    work=$(mktemp -d /tmp/vendorpatch.XXXXXX)

    echo ">> extracting $src ..."
    $EROFSBIN/fsck.erofs --extract="$work/root" --force --preserve --xattrs "$src" >/dev/null || \
        die "extraction failed"

    local prop="$work/root/build.prop"
    [ -f "$prop" ] || die "no build.prop at image root - unexpected layout"

    echo ">> editing build.prop ..."
    # the actual fix for issue #3 (idempotent): flip/inject enable_frame_rate_override=true.
    if sudo grep -q "^${FIX_PROP}=" "$prop"; then
        sudo sed -i -E "s/^${FIX_PROP}=.*/${FIX_PROP}=true/" "$prop"
    else
        printf '%s\n' '' '####################################' \
            '# OVERRIDE (issue #3): real fix -> enable frame rate override' \
            "${FIX_PROP}=true" | sudo tee -a "$prop" >/dev/null
    fi
    # hwc_apex override (original experiment; harmless: composer choice is irrelevant to the crash).
    # idempotent: strip any previous override block and any existing hwc_apex line
    sudo sed -i -e 's/^ro\.boot\.hwc_apex=.*//' -e '/# OVERRIDE (issue #3): force drmfb-composer3/d' "$prop"
    printf '%s\n' '' '####################################' "$OVERRIDE_BLOCK" | sudo tee -a "$prop" >/dev/null
    sudo tail -n 3 "$prop"

    # preserve the original image build time
    origts=$(mkfs_time_of "$src")
    T=$(date -d "$(echo "$origts" | sed -E 's/^Filesystem created: //' \
        -e 's/ [A-Z]{2,3}$//')" +%s 2>/dev/null || echo 0)
    [ "$T" -gt 0 ] || T=0

    echo ">> repacking ..."
    local out="$src.new"
    $EROFSBIN/mkfs.erofs -zlz4 --mount-point=/vendor --preserve-mtime -T "$T" "$out" "$work/root" || \
        die "repack failed"

    echo ">> sanity check: mount and verify ..."
    local chk=$(mktemp -d /tmp/vendorchk.XXXXXX)
    mount -o ro,loop "$out" "$chk" || die "verification mount failed"
    grep -q "^ro.boot.hwc_apex=2$" "$chk/build.prop" || { umount "$chk"; die "override line missing"; }
    grep -q "^${FIX_PROP}=true$" "$chk/build.prop" || { umount "$chk"; die "frame rate override fix line missing"; }
    [ "$(find "$chk" \( -type f -o -type d \) | wc -l)" -ge 1900 ] || echo "WARN: inode count looks small"
    umount "$chk"; rmdir "$chk"

    echo ">> replacing $src (backup: $src.orig) ..."
    mv -f "$src" "$src.orig"
    mv -f "$out" "$src"

    rm -rf "$work"
    echo ">> OK: $src now forces composer APEX = com.android.hardware.graphics.composer.drmfb"
}

main() {
    local target=""
    if [ $# -ge 1 ]; then
        target=$1
    else
        echo ">> searching for installed vendor.img ..."
        target=$(find_installed_vendor_img) || die "vendor.img not found / not mounted - pass the path explicitly"
    fi
    patch_image "$target"
    echo
    echo "NOTE: re-run this script after every reinstall or OTA that rewrites vendor.img."
}

main "$@"

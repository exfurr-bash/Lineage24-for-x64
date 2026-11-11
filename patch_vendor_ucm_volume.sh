#!/usr/bin/env bash
# Patch vendor.img of android-system-generic-x86-64 (lineage-24.0) to fix the
# "no sound on internal speaker / analog outputs" problem (diag 2026-11-08).
#
# Root cause:
#   The ALC256 cold-boot DAC amp default is ~20% (-52.5 dB) for both playback
#   DACs (nodes 0x02 speaker / 0x03 headphone). Android's MainlineAudio HAL only
#   runs InitializeMixer (alsa-lib, 100%) for cards that appear AFTER startup
#   (e.g. USB hot-plug); the analog card 0 never gets it, and Android never
#   writes the analog mixer at all (proven by runtime capture: the DAC stayed
#   at 0x11 while volume keys were pressed and the jack was plugged/unplugged).
#   CachyOS works because systemd's alsactl restore sets the DACs at boot.
#   => force the analog DACs to full scale via UCM, which the HAL applies on
#      every verb/device activation (proven: the Switch cset in the same files
#      does reach the hardware).
#
# Files touched inside /vendor:
#   etc/alsa/ucm2/Intel/sof-hda-dsp/HiFi.conf      (SectionVerb EnableSequence)
#   etc/alsa/ucm2/HDA/HiFi-spk.conf                (Speaker device EnableSequence)
#   etc/alsa/ucm2/HDA/HiFi-analog.conf             (Headphones device EnableSequence)
#
# Usage:
#   sudo ./patch_vendor_ucm_volume.sh [path/to/vendor.img]
# Idempotent. Requires the erofs tools in extracted/erofs-inst/bin.
set -euo pipefail

EROFSDIR_AT_DEFAULTS=(
    /home/iris/android17/extracted/erofs-inst/bin
)
[ -n "${EROFSDIR:-}" ] || EROFSDIR=$(dirname "$(readlink -f "$0")")/extracted/erofs-inst/bin
for d in "$EROFSDIR" "${EROFSDIR_AT_DEFAULTS[@]}" /usr/local/bin; do
    if [ -x "$d/mkfs.erofs" ]; then EROFSBIN="$d"; break; fi
done
[ -n "${EROFSBIN:-}" ] || { echo "ERROR: mkfs.erofs not found (set EROFSDIR)" >&2; exit 1; }

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run me as root (need to preserve image owner/permissions)"; }

mkfs_time_of() {
    $EROFSBIN/dump.erofs -s "$1" 2>/dev/null | awk '/Filesystem created/ {ts=$0}'
}

main() {
    local target=""
    if [ $# -ge 1 ]; then target=$1
    else
        for cand in /mnt/p7/android-Generic_x86_64/vendor.img; do
            [ -f "$cand" ] && target="$cand" && break
        done
    fi
    [ -n "${target:-}" ] || die "pass the vendor.img path explicitly"
    need_root
    [ -f "$target" ] || die "no such file: $target"

    local work
    work=$(mktemp -d /tmp/vucmpatch.XXXXXX)

    echo ">> extracting $target ..."
    $EROFSBIN/fsck.erofs --extract="$work/root" --force --preserve --xattrs "$target" >/dev/null || die "extraction failed"

    local base="$work/root/etc/alsa/ucm2"
    local hifi="$base/Intel/sof-hda-dsp/HiFi.conf"
    local spk="$base/HDA/HiFi-spk.conf"
    local analog="$base/HDA/HiFi-analog.conf"
    for f in "$hifi" "$spk" "$analog"; do [ -f "$f" ] || die "missing UCM file: $f"; done

    echo ">> editing UCM files ..."
    sudo -E python3 - "$hifi" "$spk" "$analog" <<'PY'
import sys

MARK = "--> NO-SOUND FIX marker (2026-11-08) <--"

def strip_old(lines):
    """Remove any previously inserted fix block (idempotency)."""
    out, skip = [], 0
    i = 0
    while i < len(lines):
        ln = lines[i]
        stripped = ln.strip()
        if stripped.startswith("# NO-SOUND FIX (2026-11-08):"):
            skip = 6  # 3 comment + 3 cset lines
            i += skip
            continue
        if stripped.startswith("# --> NO-SOUND FIX marker") or stripped == MARK:
            i += 1
            continue
        out.append(ln)
        i += 1
    return out

def insert_after_enable(lines, add):
    final, done = [], False
    for ln in lines:
        final.append(ln)
        if not done and ln.strip() == "EnableSequence [":
            final.extend(add)
            done = True
    return final, done

hifi, spk, analog = sys.argv[1:4]

# ---- A) SectionVerb of sof-hda-dsp/HiFi.conf -------------------------------
lines = strip_old(open(hifi).read().split("\n"))
add = [
    "\t\t# NO-SOUND FIX (2026-11-08): the ALC256 cold-boot DAC amp default is ~20%",
    "\t\t# (-52.5 dB) and Android never initializes the analog card mixer; force",
    "\t\t# the analog DACs to full scale (framework volume stays software-only).",
    "\t\tcset \"name='Master Playback Volume' 100%\"",
    "\t\tcset \"name='Speaker Playback Volume' 100%\"",
    "\t\tcset \"name='Headphone Playback Volume' 80%\"",
    "\t\t# " + MARK,
]
final, done = insert_after_enable(lines, add)
print(("OK " if done else "FAIL ") + "verb EditSequence insertion (HiFi.conf)")
open(hifi, "w").write("\n".join(final))

# ---- B) Speaker device: put the DAC cset before the switch cset --------------
txt = open(spk).read()
if "NO-SOUND FIX:" not in txt:
    old = "\t\t\tEnableSequence [\n\t\t\t\tcset \"name='Speaker Playback Switch' on\"\n"
    new = (
        "\t\t\tEnableSequence [\n"
        "\t\t\t\t# NO-SOUND FIX (2026-11-08): keep the speaker DAC at full scale\n"
        "\t\t\t\tcset \"name='Speaker Playback Volume' 100%\"\n"
        "\t\t\t\tcset \"name='Speaker Playback Switch' on\"\n"
    )
    if old in txt:
        open(spk, "w").write(txt.replace(old, new))
        print("OK     speaker device cset")
    else:
        print("FAIL   speaker device: pattern not found")
else:
    print("OK     speaker device cset (already present)")

# ---- C) Headphones device: same idea ----------------------------------------
txt = open(analog).read()
if "NO-SOUND FIX:" not in txt:
    old = "\t\t\t\tEnableSequence [\n\t\t\t\t\tcset \"name='Headphone Playback Switch' on\"\n"
    new = (
        "\t\t\t\tEnableSequence [\n"
        "\t\t\t\t\t# NO-SOUND FIX (2026-11-08): keep the headphone DAC at 80% (-6.75 dB)\n"
        "\t\t\t\t\tcset \"name='Headphone Playback Volume' 80%\"\n"
        "\t\t\t\t\tcset \"name='Headphone Playback Switch' on\"\n"
    )
    if old in txt:
        open(analog, "w").write(txt.replace(old, new))
        print("OK     headphones device cset")
    else:
        print("FAIL   headphones device: pattern not found")
else:
    print("OK     headphones device cset (already present)")
PY

    echo ">> resulting files (grep do fix):"
    sudo grep -n "NO-SOUND FIX\|cset \"name='.*Playback Volume'" "$hifi" "$spk" "$analog" | sed 's/^/   /'

    echo ">> repacking ..."
    # preserve image build time
    local out="$target.new"
    local ts orig
    orig=$($EROFSBIN/dump.erofs -s "$target" 2>/dev/null | awk '/Filesystem created/ {ts=$0; sub(/^Filesystem created: /,"",ts)} END{print ts}')
    T=0
    if [ -n "${orig:-}" ]; then
        T=$(date -u -d "$(echo "$orig")" +%s 2>/dev/null || echo 0) || T=0
    fi
    [ "$T" -gt 0 ] 2>/dev/null || T=0
    if [ "$T" -gt 0 ]; then
        $EROFSBIN/mkfs.erofs -zlz4 --mount-point=/vendor --preserve-mtime -T "$T" "$out" "$work/root" || die "repack failed"
    else
        $EROFSBIN/mkfs.erofs -zlz4 --mount-point=/vendor --preserve-mtime "$out" "$work/root" || die "repack failed"
    fi

    echo ">> sanity check ..."
    local chk
    chk=$(mktemp -d /tmp/vucmchk.XXXXXX)
    mount -o ro,loop "$out" "$chk" || die "verification mount failed"
    grep -q "name='Speaker Playback Volume' 100%" "$chk/etc/alsa/ucm2/Intel/sof-hda-dsp/HiFi.conf" || { umount "$chk"; die "verb csets missing in HiFi.conf"; }
    grep -q "NO-SOUND FIX" "$chk/etc/alsa/ucm2/HDA/HiFi-spk.conf" || { umount "$chk"; die "speaker cset missing"; }
    grep -q "NO-SOUND FIX" "$chk/etc/alsa/ucm2/HDA/HiFi-analog.conf" || { umount "$chk"; die "headphones cset missing"; }
    grep -q "^ro.surface_flinger.enable_frame_rate_override=true$" "$chk/build.prop" || echo "WARN: issue#3 fix line missing from build.prop"
    umount "$chk"; rmdir "$chk"

    echo ">> replacing (backup: $target.before_ucm) ..."
    cp -f "$target" "$target.before_ucm"
    mv -f "$out" "$target"

    rm -rf "$work"
    echo ">> OK: UCM now forces the analog DACs to full scale."
    echo
    echo "NOTE: user-facing effect: speaker + headphones at 100%/80% scale at every"
    echo "      UCM verb/device activation; the framework volume continues applied in"
    echo "      software. Re-run after reinstall/OTA."
}

main "$@"

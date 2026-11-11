#!/usr/bin/env bash
# Collect LineageOS bootloop diagnostics produced by the
# "Live (persistent logs on host disk, issue#3)" boot entry.
#
# Logs live directly in the bind-mapped android dir (host ext4):
#   /home/iris/android17/android-Generic_x86_64/{userdata,metadata,cache}
#
# Usage: sudo bash collect_bootloop_logs.sh [outdir]
set -uo pipefail
OUT=${1:-/home/iris/android17/diag_$(date +%Y%m%d_%H%M%S)}
BASE=/mnt/p7/android-Generic_x86_64   # bind-mapped /data + /metadata for the dbg boot entry
mountpoint -q /mnt/p7 || sudo mount /dev/nvme0n1p7 /mnt/p7
mkdir -p "$OUT"

echo ">> tombstones"
[ -d "$BASE/userdata/tombstones" ] && cp -a "$BASE/userdata/tombstones" "$OUT/" 2>/dev/null
echo ">> dropbox (crash entries)"
[ -d "$BASE/userdata/system/dropbox" ] && cp -a "$BASE/userdata/system/dropbox" "$OUT/" 2>/dev/null
echo ">> early logcat"
[ -f "$BASE/metadata/early_logcat.log" ] && cp -a "$BASE/metadata/early_logcat.log" "$OUT/"
echo ">> anr"
[ -d "$BASE/userdata/anr" ] && cp -a "$BASE/userdata/anr" "$OUT/" 2>/dev/null
echo ">> bootcfg"
grep -E "android_dir_dev|mount_userdata|save_early|mount_system|live=" "$BASE/metadata"/* 2>/dev/null | head -5

echo ">> summary"
wc -l "$OUT"/* 2>/dev/null | tail -n +1 | head -10
if [ -d "$OUT/dropbox" ]; then
    echo "-- crash classes:"
    grep -hoE "^Process: [^ ]+|^Crash Type: [^ ]+|SIG[A-Z]+|[A-Z][a-z]+Exception" \
         "$OUT/dropbox"/* 2>/dev/null | sort | uniq -c | sort -rn | head
fi
echo "OUT=$OUT"

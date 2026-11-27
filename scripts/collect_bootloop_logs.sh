#!/usr/bin/env bash
# Copia logs de diagnóstico de um android-Generic_x86_64 já montado.
#
# Uso: scripts/collect_bootloop_logs.sh [android-dir] [outdir]
# Por padrão lê de ANDROID_MOUNT/android-Generic_x86_64 e grava em logs/.
# A partição de origem não é montada nem alterada por este script.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"
enable_err_trap

DEFAULT_BASE=$ANDROID_MOUNT/android-Generic_x86_64
if [ -d "$ANDROID_MOUNT/metadata" ]; then
  DEFAULT_BASE=$ANDROID_MOUNT
fi
BASE=${1:-$DEFAULT_BASE}
OUT=${2:-$LOG_DIR/diag_$(date +%Y%m%d-%H%M%S)}

[ "$#" -le 2 ] || die "uso: collect_bootloop_logs.sh [android-dir] [outdir]"
[ -d "$BASE/metadata" ] || die "metadata não encontrada em $BASE; monte a partição ou passe android-dir"
mkdir -p "$OUT"

copy_if_present() {
  local rel=$1
  if [ -e "$BASE/$rel" ]; then
    cp -a "$BASE/$rel" "$OUT/"
  else
    log "ausente: $rel"
  fi
}

section "coletando logs"
copy_if_present userdata/tombstones
copy_if_present userdata/system/dropbox
copy_if_present metadata/early_logcat.log
copy_if_present userdata/anr

section "configuração de boot"
if compgen -G "$BASE/metadata/*" >/dev/null; then
  grep -E "android_dir_dev|mount_userdata|save_early|mount_system|live=" \
    "$BASE/metadata"/* 2>/dev/null | head -5 || true
fi

section "resumo"
if compgen -G "$OUT/*" >/dev/null; then
  wc -l "$OUT"/* 2>/dev/null | head -10 || true
fi
if [ -d "$OUT/dropbox" ]; then
  echo "-- classes de crash:"
  grep -hoE "^Process: [^ ]+|^Crash Type: [^ ]+|SIG[A-Z]+|[A-Z][a-z]+Exception" \
    "$OUT/dropbox"/* 2>/dev/null | sort | uniq -c | sort -rn | head || true
fi
ok "logs copiados para $OUT"

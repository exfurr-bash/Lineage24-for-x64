#!/usr/bin/env bash
# Pipeline único e idempotente de composição do vendor.img.
#
# Extrai a imagem uma única vez, aplica os patches pedidos (HWC, UCM, Vulkan,
# Bluetooth desktop), valida e repacka com o mtime original. O resultado tem
# um manifesto com sha256 dos insumos e a lista de arquivos adicionados.
#
# Uso:
#   scripts/build_vendor.sh --all                  # HWC + UCM + Vulkan + BT
#   scripts/build_vendor.sh --vulkan               # só Vulkan
#   scripts/build_vendor.sh --hwc --out vendor.ksu.img
#   scripts/build_vendor.sh --check-only
#   scripts/build_vendor.sh --rollback
#
# Fontes:
#   --base IMG       padrão: $ANDROID_DIR/vendor.img
#   --out IMG        padrão: $ANDROID_DIR/vendor.ksu.img
#   --bt-source IMG|DIR  padrão: $GBOS_PARTS_DIR/vendor_a.img
#   --xmldir DIR     padrão: $PROJECT_ROOT/vendor-vulkan-xmls
#
# Requer root (xattrs/mount loop) e erofs-utils.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/erofs.sh"
enable_err_trap

BASE=${BASE:-$ANDROID_DIR/vendor.img}
OUT=$ANDROID_DIR/vendor.ksu.img
BT_SOURCE=${BT_SOURCE:-$GBOS_PARTS_DIR/vendor_a.img}
XMLDIR=$PROJECT_ROOT/vendor-vulkan-xmls
DO_HWC=0 DO_UCM=0 DO_VULKAN=0 DO_BT=0
CHECK_ONLY=0 ROLLBACK=0 DRY=0
KEEP_TMP=0

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE=${2:?}; shift ;;
    --out) OUT=${2:?}; shift ;;
    --bt-source) BT_SOURCE=${2:?}; shift ;;
    --xmldir) XMLDIR=${2:?}; shift ;;
    --hwc) DO_HWC=1 ;;
    --ucm) DO_UCM=1 ;;
    --vulkan) DO_VULKAN=1 ;;
    --bt) DO_BT=1 ;;
    --all) DO_HWC=1; DO_UCM=1; DO_VULKAN=1; DO_BT=1 ;;
    --check-only) CHECK_ONLY=1 ;;
    --rollback) ROLLBACK=1 ;;
    --dry-run) DRY=1 ;;
    --keep-tmp) KEEP_TMP=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "opção desconhecida: $1" ;;
  esac
  shift
done

[ "$OUT" != "$BASE" ] || die "a saída deve ser diferente da imagem base para preservar o stock: $BASE"

rollback() {
  require_root
  local base_name latest expected got
  base_name=$(basename "$BASE")
  latest=$(find "$BACKUP_DIR/runs" -maxdepth 2 -type d -name "*-build-vendor" 2>/dev/null | sort | tail -1)
  [ -n "$latest" ] || die "sem backup de build-vendor em $BACKUP_DIR/runs"
  if [ -f "$latest/out.path" ] && [ "$(cat "$latest/out.path")" != "$OUT" ]; then
    die "a última execução usou outra saída: $(cat "$latest/out.path")"
  fi
  if [ "$OUT" != "$BASE" ]; then
    if [ -f "$latest/out.absent" ]; then
      [ -f "$OUT" ] && [ -f "$OUT.manifest.json" ] \
        || die "saída nova ou manifesto ausente; não há como validar a remoção segura"
      expected=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["out_sha256"])' "$OUT.manifest.json")
      got=$(sha256_of "$OUT")
      [ "$expected" = "$got" ] || die "a saída mudou desde o build; preservando $OUT"
      rm -f -- "$OUT" "$OUT.manifest.json"
      ok "rollback: artefato criado nesta execução removido; base preservada"
      exit 0
    fi
    [ -f "$latest/$(basename "$OUT")" ] || die "backup não contém a saída anterior: $latest"
    cp -a --reflink=auto "$latest/$(basename "$OUT")" "$OUT"
    if [ -f "$latest/$(basename "$OUT").manifest.json" ]; then
      cp -a --reflink=auto "$latest/$(basename "$OUT").manifest.json" "$OUT.manifest.json"
    elif [ -f "$latest/manifest.absent" ]; then
      rm -f -- "$OUT.manifest.json"
    fi
    ok "rollback: saída $OUT restaurada de $latest"
    exit 0
  fi
  [ -f "$latest/$base_name" ] || die "backup não contém $base_name: $latest"
  cp -a --reflink=auto "$latest/$base_name" "$BASE"
  if [ -f "$latest/$(basename "$BASE").manifest.json" ]; then
    cp -a --reflink=auto "$latest/$(basename "$BASE").manifest.json" "$BASE.manifest.json"
  elif [ -f "$latest/manifest.absent" ]; then
    rm -f -- "$BASE.manifest.json"
  fi
  ok "rollback: $BASE restaurado de $latest"
  if [ -e "$DIRKSU/vendor.img" ] && [ "$(basename "$BASE")" = "vendor.ksu.img" ]; then
    rm -f "$DIRKSU/vendor.img"
    ln -f "$BASE" "$DIRKSU/vendor.img" 2>/dev/null || cp -lf "$BASE" "$DIRKSU/vendor.img"
  fi
  exit 0
}

[ "$ROLLBACK" = 1 ] && rollback

if [ "$DO_HWC$DO_UCM$DO_VULKAN$DO_BT" = "0000" ] && [ "$CHECK_ONLY" = 0 ]; then
  die "nada a fazer: use --hwc/--ucm/--vulkan/--bt/--all ou --check-only"
fi

[ -f "$BASE" ] || die "vendor base não existe: $BASE"
require_root
require_erofs
if [ "$DO_VULKAN" = 1 ]; then
  [ -d "$XMLDIR" ] || die "diretório de XMLs Vulkan não existe: $XMLDIR"
fi

if [ "$CHECK_ONLY" = 0 ]; then
  if [ "$DO_BT" = 1 ]; then
    if [ -d "$BT_SOURCE" ]; then
      [ -x "$BT_SOURCE/bin/hw/android.hardware.bluetooth-service.desktop" ] \
        || die "BT source não contém o HAL desktop: $BT_SOURCE"
    else
      [ -f "$BT_SOURCE" ] || die "BT source não existe: $BT_SOURCE (rode scripts/fetch_sources.sh --profile gapps)"
    fi
  fi
fi

if [ "$DRY" = 1 ]; then
  log "[dry-run] base=$BASE out=$OUT hwc=$DO_HWC ucm=$DO_UCM vulkan=$DO_VULKAN bt=$DO_BT bt_source=$BT_SOURCE"
  exit 0
fi

# O vendor.img extraído da ISO é a referência stock (workspace/android).
# Sempre guardamos uma cópia da execução antes de substituir.

WORK=$(new_tmpdir build-vendor)
TARGET=$WORK/root
SOURCE_TREE=$WORK/bt-source
log "extraindo base $(basename "$BASE")"
erofs_extract "$BASE" "$TARGET"
file_list "$TARGET" "$WORK/files.before"
BEFORE_SHA=$(sha256_of "$BASE")
MTIME=$(erofs_mtime "$BASE")

if [ "$DO_BT" = 1 ]; then
  if [ -d "$BT_SOURCE" ]; then
    SOURCE_TREE=$BT_SOURCE
  else
    log "extraindo vendor do gbOS86 ($(basename "$BT_SOURCE"))"
    erofs_extract "$BT_SOURCE" "$SOURCE_TREE"
  fi
fi

PATCH_LOG=$WORK/patches.log
: > "$PATCH_LOG"
run_patch() { log "aplicando $*"; "$@" 2>&1 | tee -a "$PATCH_LOG"; }

[ "$DO_HWC" = 1 ] && run_patch python3 "$SCRIPT_DIR/lib/vendor_patches.py" hwc "$TARGET"
[ "$DO_UCM" = 1 ] && run_patch python3 "$SCRIPT_DIR/lib/vendor_patches.py" ucm "$TARGET"
[ "$DO_VULKAN" = 1 ] && run_patch python3 "$SCRIPT_DIR/lib/vendor_patches.py" vulkan "$TARGET" "$XMLDIR"
[ "$DO_BT" = 1 ] && run_patch python3 "$SCRIPT_DIR/lib/vendor_patches.py" bt "$TARGET" "$SOURCE_TREE"

CHECK_ARGS=()
[ "$DO_HWC" = 1 ] && CHECK_ARGS+=(--hwc)
[ "$DO_UCM" = 1 ] && CHECK_ARGS+=(--ucm)
[ "$DO_VULKAN" = 1 ] && CHECK_ARGS+=(--vulkan)
[ "$DO_BT" = 1 ] && CHECK_ARGS+=(--bt)

if [ "$CHECK_ONLY" = 0 ]; then
  log "validando árvore antes do repack"
  python3 "$SCRIPT_DIR/lib/vendor_patches.py" check "$TARGET" "${CHECK_ARGS[@]}" | tee "$WORK/check.json"

  file_list "$TARGET" "$WORK/files.after"
  file_list_delta "$WORK/files.before" "$WORK/files.after" "$WORK/delta.txt" >/dev/null
  log "delta de arquivos: $(wc -l < "$WORK/delta.txt") (ver $WORK/delta.txt)"
  sed -n '1,20p' "$WORK/delta.txt" | sed 's/^/   /' || true

  TMP_OUT=$OUT.new
  erofs_repack "$TMP_OUT" "$TARGET" /vendor "$MTIME"

  log "verificação por loop mount"
  CHK=$(new_tmpdir vendor-check)
  loop_mount_ro "$TMP_OUT" "$CHK"
  [ -f "$CHK/build.prop" ] || { loop_umount "$CHK"; die "build.prop ausente na imagem nova"; }
  if [ "$DO_BT" = 1 ]; then
    [ -x "$CHK/bin/hw/android.hardware.bluetooth-service.desktop" ] || die "HAL desktop ausente"
    [ ! -e "$CHK/bin/hw/android.hardware.bluetooth-service.default" ] || die "HAL UART ainda presente"
  fi
  if [ "$DO_VULKAN" = 1 ]; then
    n=$(find "$CHK/etc/permissions" -maxdepth 1 -name '*vulkan*' -printf x 2>/dev/null | wc -c)
    [ "$n" -ge 5 ] || die "XMLs Vulkan na imagem nova: $n (esperado 5)"
  fi
  loop_umount "$CHK"

  # backup da execução e substituição atômica
  BACKUP_RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
  BACKUP_RUN_DIR="$BACKUP_DIR/runs/$BACKUP_RUN_ID-build-vendor"
  backup_run "$BASE" build-vendor "$BACKUP_RUN_ID"
  printf '%s\n' "$OUT" > "$BACKUP_RUN_DIR/out.path"
  if [ "$OUT" != "$BASE" ]; then
    if [ -f "$OUT" ]; then
      backup_run "$OUT" build-vendor "$BACKUP_RUN_ID"
    else
      : > "$BACKUP_RUN_DIR/out.absent"
    fi
  fi
  if [ -f "$OUT.manifest.json" ]; then
    backup_run "$OUT.manifest.json" build-vendor "$BACKUP_RUN_ID"
  else
    : > "$BACKUP_RUN_DIR/manifest.absent"
  fi
  mv -f "$TMP_OUT" "$OUT"
  ok "vendor novo: $OUT"

  # Atualiza o hardlink do dir -ksu, se ele existir, e confere o inode.
  if [ -e "$DIRKSU" ] && [ "$(basename "$OUT")" = "vendor.ksu.img" ]; then
    rm -f "$DIRKSU/vendor.img"
    ln -f "$OUT" "$DIRKSU/vendor.img" 2>/dev/null || cp -lf "$OUT" "$DIRKSU/vendor.img"
    i1=$(stat -c %i "$OUT"); i2=$(stat -c %i "$DIRKSU/vendor.img")
    [ "$i1" = "$i2" ] || die "hardlink -ksu/vendor.img não aponta para o inode novo ($i1 != $i2)"
    ok "hardlink -ksu/vendor.img atualizado (inode $i1)"
  fi

  # Manifesto
  python3 - "$OUT.manifest.json" <<PY
import json, hashlib, os, sys
base, out = "$BASE", "$OUT"
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(8 << 20), b""):
            h.update(b)
    return h.hexdigest()
manifest = {
  "base": base, "base_sha256": "$BEFORE_SHA",
  "out": out, "out_sha256": sha(out),
  "patches": {"hwc": bool($DO_HWC), "ucm": bool($DO_UCM),
              "vulkan": bool($DO_VULKAN), "bt": bool($DO_BT)},
  "bt_source": "$BT_SOURCE" if bool($DO_BT) else None,
  "delta": [l.strip() for l in open("$WORK/delta.txt") if l.strip()],
  "check": json.load(open("$WORK/check.json")),
}
json.dump(manifest, open(sys.argv[1], "w"), indent=2, sort_keys=True)
print("manifesto:", sys.argv[1])
PY
  ok "concluído"
else
  ok "check-only OK (nada foi repackado)"
fi

if [ "$KEEP_TMP" = 1 ]; then
  log "temporários preservados em $WORK"
  trap - EXIT
fi

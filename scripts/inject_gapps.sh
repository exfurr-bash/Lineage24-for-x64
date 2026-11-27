#!/usr/bin/env bash
# Injeta o conjunto mínimo de GApps (Play Services, Play Store, GSF e o
# APEX gmssystem) do gbOS86 num system.img do Lineage.
#
# A imagem stock nunca é sobrescrita: o resultado vai para $GAPPS_SYSTEM_IMG
# (workspace/system-gapps.img), com manifesto e backup timestamped da saída.
#
# Uso:
#   sudo scripts/inject_gapps.sh
#   sudo scripts/inject_gapps.sh --out /caminho/system-gapps.img
#   sudo scripts/inject_gapps.sh --dry-run
#   sudo scripts/inject_gapps.sh --rollback
#
# Fontes: $ANDROID_DIR/system.img + $GBOS_PARTS_DIR/{product_a,system_ext_a}.img
# (baixadas/extraídas por `make fetch` perfil gapps).
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/erofs.sh"
enable_err_trap

BASE=${BASE:-$ANDROID_DIR/system.img}
OUT=$GAPPS_SYSTEM_IMG
PRODUCT_IMG=${PRODUCT_IMG:-$GBOS_PARTS_DIR/product_a.img}
SYSTEM_EXT_IMG=${SYSTEM_EXT_IMG:-$GBOS_PARTS_DIR/system_ext_a.img}
LAYOUT=auto
DRY=0
ROLLBACK=0
KEEP_TMP=0

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE=${2:?}; shift ;;
    --out) OUT=${2:?}; shift ;;
    --product) PRODUCT_IMG=${2:?}; shift ;;
    --system-ext) SYSTEM_EXT_IMG=${2:?}; shift ;;
    --layout) LAYOUT=${2:?}; shift ;;
    --dry-run) DRY=1 ;;
    --rollback) ROLLBACK=1 ;;
    --keep-tmp) KEEP_TMP=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "opção desconhecida: $1" ;;
  esac
  shift
done

[ "$OUT" != "$BASE" ] || die "a saída deve ser diferente da imagem base para preservar o stock: $BASE"

if [ "$ROLLBACK" = 1 ]; then
  require_root
  latest=$(find "$BACKUP_DIR/runs" -maxdepth 2 -type d -name "*-inject-gapps*" 2>/dev/null | sort | tail -1)
  [ -n "$latest" ] || die "sem backup de inject-gapps em $BACKUP_DIR/runs"
  if [ -f "$latest/out.path" ] && [ "$(cat "$latest/out.path")" != "$OUT" ]; then
    die "a última execução usou outra saída: $(cat "$latest/out.path")"
  fi
  if [ -f "$latest/out.absent" ]; then
    [ -f "$OUT" ] && [ -f "$OUT.manifest.json" ] \
      || die "saída nova ou manifesto ausente; não há como validar a remoção segura"
    expected=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["out"]["sha256"])' "$OUT.manifest.json")
    got=$(sha256_of "$OUT")
    [ "$expected" = "$got" ] || die "a saída mudou desde a injeção; preservando $OUT"
    rm -f -- "$OUT" "$OUT.manifest.json"
    ok "rollback: imagem GApps criada nesta execução removida; base preservada"
    exit 0
  fi
  [ -f "$latest/$(basename "$OUT")" ] || die "backup não contém a saída anterior $(basename "$OUT"): $latest"
  cp -a --reflink=auto "$latest/$(basename "$OUT")" "$OUT"
  if [ -f "$latest/$(basename "$OUT").manifest.json" ]; then
    cp -a --reflink=auto "$latest/$(basename "$OUT").manifest.json" "$OUT.manifest.json"
  elif [ -f "$latest/manifest.absent" ]; then
    rm -f -- "$OUT.manifest.json"
  fi
  ok "rollback: $OUT restaurado de $latest"
  exit 0
fi

[ -f "$BASE" ] || die "system.img base não existe: $BASE (rode scripts/fetch_sources.sh)"
[ -f "$PRODUCT_IMG" ] || die "product_a.img não existe: $PRODUCT_IMG (perfil gapps)"
[ -f "$SYSTEM_EXT_IMG" ] || die "system_ext_a.img não existe: $SYSTEM_EXT_IMG (perfil gapps)"

if [ "$DRY" = 1 ]; then
  log "[dry-run] base=$BASE out=$OUT product=$PRODUCT_IMG system_ext=$SYSTEM_EXT_IMG layout=$LAYOUT"
  exit 0
fi

require_root
require_erofs
require_cmd python3
mkdir -p "$(dirname "$OUT")"
check_free_space "$(dirname "$OUT")" 12

# Backup timestamped da saída existente e do manifesto. A imagem base é sempre
# read-only para este fluxo.
BACKUP_RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
BACKUP_RUN_DIR="$BACKUP_DIR/runs/$BACKUP_RUN_ID-inject-gapps"
mkdir -p "$BACKUP_RUN_DIR"
printf '%s\n' "$OUT" > "$BACKUP_RUN_DIR/out.path"
if [ -f "$OUT" ]; then
  backup_run "$OUT" inject-gapps "$BACKUP_RUN_ID"
else
  : > "$BACKUP_RUN_DIR/out.absent"
fi
if [ -f "$OUT.manifest.json" ]; then
  backup_run "$OUT.manifest.json" inject-gapps "$BACKUP_RUN_ID"
else
  : > "$BACKUP_RUN_DIR/manifest.absent"
fi

W=$(new_tmpdir inject-gapps)
ROOT=$W/root
log "extraindo system.img stock"
erofs_extract "$BASE" "$ROOT"
MTIME=$(erofs_mtime "$BASE")

log "extraindo product_a"
erofs_extract "$PRODUCT_IMG" "$W/product"
log "extraindo system_ext_a"
erofs_extract "$SYSTEM_EXT_IMG" "$W/system_ext"

log "copiando GApps"
python3 "$SCRIPT_DIR/lib/gapps_inject.py" \
  --stock-tree "$ROOT" \
  --product-tree "$W/product" \
  --system-ext-tree "$W/system_ext" \
  --layout "$LAYOUT" \
  --manifest "$W/gapps.json" | tee "$W/gapps.log"

# Descobre o layout para usar o mount-point certo no repack.
LAYOUT_USED=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["layout"])' "$W/gapps.json")
case "$LAYOUT_USED" in
  root) MP=/ ;;
  nested) MP=/system ;;
  system) MP="$SYSTEM_MOUNT_POINT" ;;
  *) die "layout inesperado: $LAYOUT_USED" ;;
esac
log "repack EROFS (layout=$LAYOUT_USED, mount-point=$MP)"

TMP_OUT=$OUT.new
erofs_repack "$TMP_OUT" "$ROOT" "$MP" "$MTIME"

log "verificação por loop mount"
CHK=$(new_tmpdir gapps-check)
loop_mount_ro "$TMP_OUT" "$CHK"
found=0
for p in system/product/priv-app/Phonesky product/priv-app/Phonesky; do
  [ -e "$CHK/$p" ] && found=1
done
[ "$found" = 1 ] || { loop_umount "$CHK"; die "Phonesky ausente na imagem nova"; }
found=0
for p in system_ext/priv-app/GoogleServicesFramework system/system_ext/priv-app/GoogleServicesFramework; do
  [ -e "$CHK/$p" ] && found=1
done
[ "$found" = 1 ] || { loop_umount "$CHK"; die "GoogleServicesFramework ausente na imagem nova"; }
apex_count=$(find "$CHK" -maxdepth 4 -name '*com.google.android.gmssystem*' 2>/dev/null | wc -l)
[ "$apex_count" -ge 1 ] || { loop_umount "$CHK"; die "APEX gmssystem ausente na imagem nova"; }
loop_umount "$CHK"

mv -f "$TMP_OUT" "$OUT"
ok "system GApps: $OUT ($(human_size "$(stat -c %s "$OUT")"))"

# Manifesto com hashes dos insumos e da saída.
python3 - "$BASE" "$PRODUCT_IMG" "$SYSTEM_EXT_IMG" "$OUT" "$OUT.manifest.json" "$W/gapps.json" <<'PY'
import hashlib, json, os, sys
base, product, system_ext, out, manifest, gapps_json = sys.argv[1:7]
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(8 << 20), b""):
            h.update(b)
    return h.hexdigest()
data = json.load(open(gapps_json))
data["inputs"] = {
    "system": {"path": base, "sha256": sha(base)},
    "product_a": {"path": product, "sha256": sha(product)},
    "system_ext_a": {"path": system_ext, "sha256": sha(system_ext)},
}
data["out"] = {"path": out, "size": os.path.getsize(out), "sha256": sha(out)}
json.dump(data, open(manifest, "w"), indent=2, sort_keys=True)
print("manifesto:", manifest)
PY
ok "concluído"

if [ "$KEEP_TMP" = 1 ]; then
  log "temporários preservados em $W"
  trap - EXIT
fi

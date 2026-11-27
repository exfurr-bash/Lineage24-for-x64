#!/usr/bin/env bash
# Instala o kernel com KernelSU e regenera os artefatos .ksu:
#   kernel.ksu, vendor_dlkm.ksu.img, ramdisk-all-combined.ksu.img
#
# O vendor_dlkm é reconstruído com os módulos do build novo, metadata
# depmod PLANIFICADA (sem refs órfãs) e a cadeia BT acrescentada ao
# modules.load. O ramdisk tem os .ko substituídos via cpio_rewrite.py.
#
# Uso:
#   sudo scripts/install_kernel_ksu.sh
#   sudo scripts/install_kernel_ksu.sh --apply-boot
#   sudo scripts/install_kernel_ksu.sh --skip-dlkm --skip-ramdisk
#   sudo scripts/install_kernel_ksu.sh --rollback
#
# --apply-boot cria o dir android-ksu paralelo e insere a entrada GRUB.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/erofs.sh"
enable_err_trap

A=${ANDROID_DIR}
APPLY_BOOT=0
SKIP_DLKM=0
SKIP_RAMDISK=0
DO_STRIP_BTF=1
ROLLBACK=0
PYTHON=${PYTHON:-python3}

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply-boot) APPLY_BOOT=1 ;;
    --skip-dlkm) SKIP_DLKM=1 ;;
    --skip-ramdisk) SKIP_RAMDISK=1 ;;
    --no-strip-btf) DO_STRIP_BTF=0 ;;
    --rollback) ROLLBACK=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "opção desconhecida: $1" ;;
  esac
  shift
done

[ -d "$A" ] || die "android dir não existe: $A (rode scripts/fetch_sources.sh)"
require_root
[ -f "$KOUT" ] || die "bzImage não encontrado: $KOUT (rode scripts/build_kernel_ksu.sh)"
[ -d "$MODSTAGE_DIR/lib/modules" ] || die "sem módulos em $MODSTAGE_DIR/lib/modules"
MODBASE=$(find "$MODSTAGE_DIR/lib/modules" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort | head -1)
[ -n "$MODBASE" ] || die "sem subdir de módulos em $MODSTAGE_DIR/lib/modules"
require_erofs
require_cmd lz4 "$PYTHON"

# ------------------------------- helpers ----------------------------------
refresh_links() {
  [ -d "$DIRKSU" ] || return 0
  local f d
  for f in system.img vendor.img system_dlkm.img firmware.img; do
    [ -e "$A/$f" ] || continue
    if [ -e "$DIRKSU/$f" ] && [ ! -L "$DIRKSU/$f" ]; then
      # hardlink antigo: remove para recriar como symlink
      rm -f "$DIRKSU/$f"
    fi
    [ -e "$DIRKSU/$f" ] || ln -s "../$(basename "$A")/$f" "$DIRKSU/$f"
  done
  for d in cache metadata userdata; do
    [ -d "$A/$d" ] || continue
    [ -e "$DIRKSU/$d" ] || ln -s "../$(basename "$A")/$d" "$DIRKSU/$d"
  done
  if [ -f "$A/vendor_dlkm.ksu.img" ]; then
    rm -f "$DIRKSU/vendor_dlkm.img"
    ln -f "$A/vendor_dlkm.ksu.img" "$DIRKSU/vendor_dlkm.img" 2>/dev/null \
      || cp -lf "$A/vendor_dlkm.ksu.img" "$DIRKSU/vendor_dlkm.img"
    local i1 i2
    i1=$(stat -c %i "$A/vendor_dlkm.ksu.img")
    i2=$(stat -c %i "$DIRKSU/vendor_dlkm.img")
    [ "$i1" = "$i2" ] || die "hardlink vendor_dlkm.img não reflete o artefato novo ($i1 != $i2)"
    ok "hardlink -ksu/vendor_dlkm.img -> inode $i1"
  fi
}

strip_btf() {
  local ko=$1 tool=""
  for t in objcopy llvm-objcopy; do command -v "$t" >/dev/null 2>&1 && { tool=$t; break; }; done
  [ -n "$tool" ] || { warn "objcopy ausente; .BTF não removido"; return 0; }
  "$tool" --remove-section=.BTF --remove-section=.BTF.ext "$ko" 2>/dev/null || true
}

if [ "$ROLLBACK" = 1 ]; then
  latest=$(find "$BACKUP_DIR/runs" -maxdepth 2 -type d -name "*-install-ksu" 2>/dev/null | sort | tail -1)
  [ -n "$latest" ] || die "sem backup de install-ksu em $BACKUP_DIR/runs"
  for f in kernel.ksu vendor_dlkm.ksu.img ramdisk-all-combined.ksu.img; do
    [ -f "$latest/$f" ] && cp -a --reflink=auto "$latest/$f" "$A/$f" && ok "restaurado $f"
  done
  refresh_links
  exit 0
fi

# ------------------------------- backups ----------------------------------
BACKUP_RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
for f in kernel.ksu vendor_dlkm.ksu.img ramdisk-all-combined.ksu.img; do
  [ -f "$A/$f" ] && backup_run "$A/$f" install-ksu "$BACKUP_RUN_ID"
done

# ------------------------------- kernel -----------------------------------
log "kernel.ksu"
cp -f "$KOUT" "$A/kernel.ksu.new"
mv -f "$A/kernel.ksu.new" "$A/kernel.ksu"
ok "kernel: $(file -b "$A/kernel.ksu" | sed 's/^/ /')"

# ------------------------------- vendor_dlkm ------------------------------
if [ "$SKIP_DLKM" = 0 ]; then
  [ -f "$A/vendor_dlkm.img" ] || die "sem $A/vendor_dlkm.img (stock)"
  W=$(new_tmpdir dlkm)
  log "extraindo vendor_dlkm stock"
  erofs_extract "$A/vendor_dlkm.img" "$W/root"
  FLAT=$W/root/lib/modules
  [ -d "$FLAT" ] || die "vendor_dlkm sem lib/modules"
  STOCK_KO=$(count_ko "$FLAT")
  log "stock: $STOCK_KO .ko"

  find "$FLAT" -type f \( -name '*.ko' -o -name '*.ko.gz' -o -name '*.ko.xz' -o -name '*.ko.zst' \) -delete
  log "copiando módulos do build ($(count_ko "$MODBASE") .ko)"
  n=0
  while IFS= read -r ko; do
    dest="$FLAT/$(basename "$ko")"
    install -m 0644 "$ko" "$dest"
    [ "$DO_STRIP_BTF" = 1 ] && strip_btf "$dest"
    n=$((n+1))
  done < <(find "$MODBASE" -name '*.ko' -type f)
  ok "$n módulos copiados para o layout flat"
  [ "$n" -gt 0 ] || die "nenhum módulo copiado"

  [ -f "$FLAT/modules.load" ] || : > "$FLAT/modules.load"
  log "regenerando metadata depmod flat (modules.dep/alias/softdep) e modules.load"
  "$PYTHON" "$SCRIPT_DIR/lib/flatten_depmod.py" \
    --modules-root "$MODBASE" \
    --flat-dir "$FLAT" \
    --modules-load "$FLAT/modules.load" \
    --bt-modules "$BT_MODULES" \
    --builtin-list "$PROJECT_ROOT/config/known-builtins.txt" \
    --report "$W/dlkm-report.json" | tee "$W/dlkm-check.log"

  # Confere que o modules.load resultante só referencia módulos presentes.
  "$PYTHON" - "$FLAT/modules.load" "$FLAT" <<'PY'
import os, sys
load, flat = sys.argv[1:3]
have = {x[:-3] for x in os.listdir(flat) if x.endswith('.ko')}
missing = [l.strip() for l in open(load) if l.strip() and l.strip() not in have]
if missing:
    raise SystemExit("modules.load referencia módulos ausentes: " + ", ".join(missing[:20]))
print(f"modules.load OK ({len(have)} módulos flat)")
PY

  MT=$(erofs_mtime "$A/vendor_dlkm.img")
  erofs_repack "$A/vendor_dlkm.ksu.img.new" "$W/root" /vendor_dlkm "$MT"
  CHK=$(new_tmpdir dlkm-check)
  loop_mount_ro "$A/vendor_dlkm.ksu.img.new" "$CHK"
  NEW_KO=$(count_ko "$CHK")
  [ "$NEW_KO" -gt 0 ] || { loop_umount "$CHK"; die "imagem nova sem .ko"; }
  for m in $BT_MODULES; do
    [ -f "$CHK/lib/modules/$m.ko" ] || warn "módulo BT ausente na imagem: $m.ko"
  done
  dep_lines=$(grep -vc '^$' "$CHK/lib/modules/modules.dep" || true)
  loop_umount "$CHK"
  mv -f "$A/vendor_dlkm.ksu.img.new" "$A/vendor_dlkm.ksu.img"
  ok "vendor_dlkm.ksu.img: $NEW_KO .ko (stock $STOCK_KO; $dep_lines linhas em modules.dep)"
fi

# ------------------------------- ramdisk ----------------------------------
if [ "$SKIP_RAMDISK" = 0 ]; then
  [ -f "$A/ramdisk-all-combined.img" ] || die "sem $A/ramdisk-all-combined.img (stock)"
  R=$(new_tmpdir ramdisk)
  log "descomprimindo ramdisk stock"
  lz4 -d -q "$A/ramdisk-all-combined.img" "$R/rd.cpio" || die "falha ao descomprimir ramdisk"
  "$PYTHON" "$SCRIPT_DIR/lib/cpio_rewrite.py" \
    --cpio "$R/rd.cpio" --modules-dir "$MODBASE" --out "$R/rd.new.cpio" \
    --report "$R/cpio-report.json"
  log "recomprimindo lz4 legacy"
  lz4 -l -q -9 "$R/rd.new.cpio" "$R/rd-new.lz4"
  lz4 -d -q "$R/rd-new.lz4" "$R/verify.cpio"
  cmp -s "$R/rd.new.cpio" "$R/verify.cpio" || die "round-trip do ramdisk difere"
  mv -f "$R/rd-new.lz4" "$A/ramdisk-all-combined.ksu.img"
  ok "ramdisk-all-combined.ksu.img atualizado"
fi

# ------------------------------- links + GRUB -----------------------------
refresh_links

if [ "$APPLY_BOOT" = 1 ]; then
  [ -n "${GRUB_CFG:-}" ] || die "defina GRUB_CFG em config.env para --apply-boot"
  [ -f "$GRUB_CFG" ] || die "grub.cfg não existe: $GRUB_CFG"
  mkdir -p "$DIRKSU"
  refresh_links
  backup_run "$GRUB_CFG" grub
  python3 "$SCRIPT_DIR/lib/grub_patch.py" entry --cfg "$GRUB_CFG"
  python3 "$SCRIPT_DIR/lib/grub_patch.py" check-entry --cfg "$GRUB_CFG"
  if command -v grub-script-check >/dev/null 2>&1; then
    grub-script-check "$GRUB_CFG" || die "grub-script-check rejeitou o grub.cfg novo"
  fi
  ok "entrada GRUB atualizada"
else
  log "GRUB não alterado (use --apply-boot)"
fi

section "artefatos"
ls -la "$A"/kernel.ksu "$A"/vendor_dlkm.ksu.img "$A"/ramdisk-all-combined.ksu.img 2>/dev/null || true
ok "concluído"

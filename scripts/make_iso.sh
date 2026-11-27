#!/usr/bin/env bash
# Reconstrói a ISO live modificada (KernelSU + Vulkan [+ GApps]) a partir
# do esqueleto de boot da ISO oficial e dos artefatos do workspace.
#
# Uso:
#   sudo scripts/make_iso.sh --variant ksu
#   sudo scripts/make_iso.sh --variant gapps --system-img workspace/system-gapps.img
#   sudo scripts/make_iso.sh --android workspace/android --out dist/test.iso
#
# Variantes:
#   ksu     kernel.ksu + ramdisk.ksu + vendor.ksu + vendor_dlkm.ksu
#   gapps   idem + system.img do GApps ($GAPPS_SYSTEM_IMG)
#
# A ISO resultante é live (mount_userdata=tmpfs): cada boot começa do zero.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"
enable_err_trap

VARIANT=ksu
A=$ANDROID_DIR
ORIGISO=$ISO_FILE
OUT=""
SYSIMG=""
KEEP_STAGE=0

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --variant) VARIANT=${2:?}; shift ;;
    --android) A=${2:?}; shift ;;
    --iso) ORIGISO=${2:?}; shift ;;
    --out) OUT=${2:?}; shift ;;
    --system-img) SYSIMG=${2:?}; shift ;;
    --keep-stage) KEEP_STAGE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "opção desconhecida: $1" ;;
  esac
  shift
done

case "$VARIANT" in
  ksu) SUFFIX=ksu-vulkan ;;
  gapps) SUFFIX=ksu-vulkan-gapps ;;
  *) die "variante inválida: $VARIANT (ksu|gapps)" ;;
esac

[ -d "$A" ] || die "android dir não existe: $A"
[ -f "$ORIGISO" ] || die "ISO original não existe: $ORIGISO (rode scripts/fetch_sources.sh)"
require_cmd xorriso python3
require_root

if [ -z "$OUT" ]; then
  OUT=$DIST_DIR/lineage-24.0-${BASE_RELEASE}-UNOFFICIAL-0xCAFEBABE-Generic_x86_64-live-${SUFFIX}.iso
fi
mkdir -p "$(dirname "$OUT")"
check_free_space "$(dirname "$OUT")" 12

# ------------------------------- insumos ----------------------------------
kernel=$A/kernel.ksu
ramdisk=$A/ramdisk-all-combined.ksu.img
dlkm=$A/vendor_dlkm.ksu.img
vendor=$A/vendor.ksu.img
[ -f "$vendor" ] || vendor=$A/vendor.img
[ -f "$kernel" ] || die "sem $kernel (rode scripts/install_kernel_ksu.sh)"
[ -f "$ramdisk" ] || die "sem $ramdisk (rode scripts/install_kernel_ksu.sh)"
[ -f "$dlkm" ] || die "sem $dlkm (rode scripts/install_kernel_ksu.sh)"
[ -f "$vendor" ] || die "sem $A/vendor.ksu.img nem $A/vendor.img"
[ -f "$A/system.img" ] || die "sem $A/system.img"
[ -f "$A/system_dlkm.img" ] || die "sem $A/system_dlkm.img"
[ -f "$A/firmware.img" ] || die "sem $A/firmware.img (obrigatório no generic_init)"

system=$A/system.img
if [ "$VARIANT" = gapps ]; then
  system=${SYSIMG:-$GAPPS_SYSTEM_IMG}
  [ -f "$system" ] || die "sem system GApps: $system (rode make gapps ou make fetch PROFILE=github-gapps)"
fi

file_is_bzimage "$kernel" || die "$kernel não é um bzImage"
for f in "$ramdisk" "$dlkm" "$vendor" "$system" "$A/system_dlkm.img" "$A/firmware.img"; do
  [ -s "$f" ] || die "arquivo vazio/ausente: $f"
done
log "variante: $VARIANT"
log "kernel:  $kernel ($(kernel_version_of "$kernel"))"
log "system:  $system ($(human_size "$(stat -c %s "$system")"))"

# ------------------------------- stage ------------------------------------
STAGE=$(new_tmpdir mkiso)
log "stage: $STAGE"
mkdir -p "$STAGE"

extract_path() { # extract_path /caminho [obrigatório]
  local p=$1 required=${2:-0} name
  name=$(basename "$p")
  if xorriso -osirrox on -indev "$ORIGISO" -extract "$p" "$STAGE/$name" >/dev/null 2>&1 \
      && [ -e "$STAGE/$name" ]; then
    return 0
  fi
  if [ "$required" = 1 ]; then
    die "não consegui extrair $p de $ORIGISO"
  fi
  warn "ausente na ISO original (opcional): $p"
}

log "[1/3] esqueleto de boot da ISO oficial"
extract_path /boot 1
extract_path /efi 1
extract_path /.disk 0
extract_path /System 0
extract_path /mach_kernel 0
extract_path /efi.img 1
chmod -R u+w "$STAGE"

log "[2/3] imagens do android dir"
INST=$STAGE/android-Generic_x86_64
mkdir -p "$INST"
cp -a --reflink=auto "$kernel"  "$INST/kernel"
cp -a --reflink=auto "$ramdisk" "$INST/ramdisk-all-combined.img"
cp -a --reflink=auto "$dlkm"    "$INST/vendor_dlkm.img"
cp -a --reflink=auto "$vendor"  "$INST/vendor.img"
cp -a --reflink=auto "$system"  "$INST/system.img"
cp -a --reflink=auto "$A/system_dlkm.img" "$INST/system_dlkm.img"
cp -a --reflink=auto "$A/firmware.img"    "$INST/firmware.img"
( cd "$INST" && sha256sum kernel ramdisk-all-combined.img vendor_dlkm.img vendor.img \
    system.img system_dlkm.img firmware.img > SHA256SUMS )
ls -la "$INST"

log "[3/3] grub.cfg + xorriso"
CFG=$STAGE/boot/grub/grub.cfg
[ -f "$CFG" ] || die "grub.cfg não encontrado no esqueleto: $CFG"
python3 "$SCRIPT_DIR/lib/grub_patch.py" iso-titles --cfg "$CFG" --variant "$VARIANT"
grep -c 'menuentry\|submenu' "$CFG" | sed 's/^/   entradas de menu: /'

MODDATE="${BASE_RELEASE}16335700"
[[ "$MODDATE" =~ ^[0-9]{16}$ ]] || die "modification-date inválida: $MODDATE"
log "modification-date: $MODDATE (reprodutível para a base $BASE_RELEASE)"

xorriso -as mkisofs \
  -V 'ISOIMAGE' \
  --modification-date="$MODDATE" \
  --grub2-mbr --interval:local_fs:0s-15s:zero_mbrpt,zero_gpt,zero_apm:"$ORIGISO" \
  --protective-msdos-label \
  -partition_cyl_align off \
  -partition_offset 0 \
  -partition_hd_cyl 170 \
  -partition_sec_hd 32 \
  -apm-block-size 2048 \
  -hfsplus \
  -efi-boot-part --efi-boot-image \
  -c '/boot.catalog' \
  -b '/boot/grub/i386-pc/eltorito.img' \
  -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
  -eltorito-alt-boot -e '/efi.img' -no-emul-boot \
  -o "$OUT" "$STAGE"

sha256_of "$OUT" > "$OUT.sha256"
ok "ISO pronta: $OUT ($(human_size "$(stat -c %s "$OUT")"))"
ok "sha256: $(cat "$OUT.sha256")"
log "teste antes de gravar: make test-qemu ISO=$OUT"

if [ "$KEEP_STAGE" = 1 ]; then
  log "stage preservado em $STAGE"
  trap - EXIT
fi

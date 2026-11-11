#!/usr/bin/env bash
# Fase 2 — habilita Vulkan de hardware (ANV/Mesa) no Generic x86_64.
# Causa raiz: o apex vulkan escolhido p/ GPU de hardware é o `no_apex`, que é
# VAZIO — os 5 XMLs de feature (FEATURE_VULKAN) só existem no payload do apex
# swiftshader, e payloads de apex são AVB-assinados (não dá p/ editar). Mas
# vendor.img é EROFS sem assinatura: repack (mesmo fluxo do vendor_dlkm)
# adicionando os XMLs em /vendor/etc/permissions/.
#
# Estratégia (espelha install_kernel_ksu.sh):
#   - dir principal: vendor.img STOCK NUNCA tocado; cria vendor.ksu.img ao lado
#     (o dynamic_mount_handler ignora nomes UNKNOWN como "vendor.ksu.img")
#   - dir -ksu: substitui o symlink vendor.img -> ../…/vendor.img por um
#     HARDLINK vendor.img -> vendor.ksu.img
#   - rollback: rm -f dir-ksu/vendor.img && ln -s ../android-Generic_x86_64/vendor.img dir-ksu/vendor.img
#
# Uso: sudo ./install_vendor_vulkan.sh          # prepara backup+vendor.ksu.img+hardlink
#      sudo ./install_vendor_vulkan.sh --rollback  # volta o symlink (stock)
set -euo pipefail
A=/mnt/p7/android-Generic_x86_64
DIRKSU=/mnt/p7/android-Generic_x86_64-ksu
BK=/home/iris/android17/backup-vendor-vulkan-20261110
XMLS=/home/iris/android17/vendor-vulkan-xmls
EROFSDIR=/home/iris/android17/extracted/erofs-inst/bin
XMLLIST=(
  android.hardware.vulkan.compute-0.prebuilt.xml
  android.hardware.vulkan.level-1.prebuilt.xml
  android.hardware.vulkan.version-1_3.prebuilt.xml
  android.software.opengles.deqp.level-latest.prebuilt.xml
  android.software.vulkan.deqp.level-latest.prebuilt.xml
)
die(){ echo "ERRO: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "rode com sudo"
mountpoint -q /mnt/p7 || mount /dev/nvme0n1p7 /mnt/p7

if [ "${1:-}" = "--rollback" ]; then
  rm -f "$DIRKSU/vendor.img"
  ln -s ../android-Generic_x86_64/vendor.img "$DIRKSU/vendor.img"
  echo "rollback ok: $DIRKSU/vendor.img -> stock (symlink)"
  exit 0
fi

echo ">> [1/4] backup do vendor.img atual (já modificada uma vez: existem .before_ucm/.orig)"
mkdir -p "$BK"
cp -a "$A/vendor.img" "$BK/vendor.img.pre-vulkan"
sha256sum "$A/vendor.img" | awk '{print "   sha256(atual): " $1}'

echo ">> [2/4] extract EROFS + adicionar XMLs de feature"
W=$(mktemp -d /tmp/vvendor.XXXXXX)
$EROFSDIR/fsck.erofs --extract="$W/root" --force --preserve --xattrs \
    "$A/vendor.img" >/dev/null || die "extract vendor falhou"
echo "   arquivos originais: $(find "$W/root" -type f | wc -l)"
# lista original ANTES de adicionar os XMLs (base do sanity de delta)
( cd "$W/root" && find . -type f | sort ) > /tmp/vv-orig.list
for x in "${XMLLIST[@]}"; do
  install -m 0644 "$XMLS/$x" "$W/root/etc/permissions/$x" || die "cópia $x falhou"
done
echo "   XMLs vulkan em etc/permissions: $(ls "$W/root/etc/permissions" | grep -c vulkan)"

echo ">> [3/4] mkfs.erofs (lz4, mtime preservado)"
TS=$($EROFSDIR/dump.erofs -s "$A/vendor.img" 2>/dev/null | awk '/Filesystem created/ {sub(/^Filesystem created: /,"");sub(/ [A-Z]{2,3}$/,"");print;exit}')
T=$(date -u -d "$TS" +%s 2>/dev/null || echo 0)
if [ "$T" -gt 0 ]; then
  $EROFSDIR/mkfs.erofs -zlz4 --mount-point=/vendor --preserve-mtime -T "$T" \
    "$A/vendor.ksu.img.new" "$W/root" || die "mkfs vendor falhou"
else
  $EROFSDIR/mkfs.erofs -zlz4 --mount-point=/vendor --preserve-mtime \
    "$A/vendor.ksu.img.new" "$W/root" || die "mkfs vendor falhou"
fi

echo ">> [4/4] sanity + instalação"
V=$(mktemp -d /tmp/vvchk.XXXXXX); mount -o ro,loop "$A/vendor.ksu.img.new" "$V"
for x in "${XMLLIST[@]}"; do
  [ -f "$V/etc/permissions/$x" ] || die "sanity: $x ausente na imagem nova"
done
( cd "$V" && find . -type f | sort ) > /tmp/vv-new.list
DIFFN=$(comm -3 /tmp/vv-orig.list /tmp/vv-new.list | grep -cv '^ *$' || true)
EXTRA=$(comm -13 /tmp/vv-orig.list /tmp/vv-new.list | head -8)
echo "   arquivos: origem $(wc -l < /tmp/vv-orig.list) | nova $(wc -l < /tmp/vv-new.list) | delta $DIFFN (esperado 5)"
[ "$DIFFN" = "5" ] || { echo "   EXTRA/DIF: $EXTRA"; die "sanity: delta != 5 XMLs"; }
umount "$V"; rmdir "$V"; rm -rf "$W"
mv -f "$A/vendor.ksu.img.new" "$A/vendor.ksu.img"

rm -f "$DIRKSU/vendor.img"
ln -f "$A/vendor.ksu.img" "$DIRKSU/vendor.img" 2>/dev/null \
  || cp -lf "$A/vendor.ksu.img" "$DIRKSU/vendor.img"
NL=$(stat -c %h "$A/vendor.ksu.img")
echo "   nlink de vendor.ksu.img: $NL (esperado 2)"
[ "$NL" = "2" ] || die "nlink != 2"

echo
echo ">> pronto:"
ls -la "$A/vendor.ksu.img" "$DIRKSU/vendor.img"
echo ">> rollback: sudo ./install_vendor_vulkan.sh --rollback"

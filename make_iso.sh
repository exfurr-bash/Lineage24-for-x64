#!/usr/bin/env bash
# Recria a ISO "Live" do Generic x86_64 com KernelSU + Vulkan habilitado,
# a partir de:
#   - a ISO oficial (esqueleto de boot: grub, efi.img, MBR grub2, El Torito)
#   - o dir Android do SSD (com os artefatos .ksu: kernel, ramdisk,
#     vendor_dlkm e o vendor.img repackado com os XMLs de feature Vulkan)
#
# A ISO resultante é "live" (mount_userdata=tmpfs — sem userdata persistente,
# cada boot é fresco) e herda o menu do projeto, com os menus renomeados
# "(KernelSU + Vulkan)" + uma entrada de diagnóstico androidboot.vulkan_apex=2.
#
# Uso:  sudo ./make_iso.sh [dir-android] [iso-original] [saida]
# Padrões: /mnt/p7/android-Generic_x86_64  /home/iris/lineage-24.0.iso  ./out.iso
set -euo pipefail
ASRC=${1:-/mnt/p7/android-Generic_x86_64}
ORIGISO=${2:-/home/iris/lineage-24.0.iso}
OUT=${3:-/home/iris/iso-build/lineage-24.0-20261111-UNOFFICIAL-0xCAFEBABE-Generic_x86_64-live-ksu-vulkan.iso}
STAGE=$(mktemp -d /tmp/mkiso-stage.XXXXXX)
X="xorriso -osirrox on -indev $ORIGISO"
die(){ echo "ERRO: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "rode com sudo"

echo ">> [1/4] esqueleto de boot da ISO oficial"
$X -extract /boot "$STAGE/boot"
$X -extract /efi   "$STAGE/efi"
$X -extract /.disk "$STAGE/.disk"
$X -extract /System "$STAGE/System"
$X -extract /mach_kernel "$STAGE/mach_kernel"
$X -extract /efi.img "$STAGE/efi.img"
chmod -R u+w "$STAGE"

echo ">> [2/4] imagens do dir Android"
mkdir -p "$STAGE/android-Generic_x86_64"
cp -a "$ASRC/kernel.ksu"                   "$STAGE/android-Generic_x86_64/kernel"
cp -a "$ASRC/ramdisk-all-combined.ksu.img" "$STAGE/android-Generic_x86_64/ramdisk-all-combined.img"
cp -a "$ASRC/vendor_dlkm.ksu.img"          "$STAGE/android-Generic_x86_64/vendor_dlkm.img"
cp -a "$ASRC/vendor.ksu.img"               "$STAGE/android-Generic_x86_64/vendor.img"
for f in system.img system_dlkm.img firmware.img; do
  cp -a "$ASRC/$f" "$STAGE/android-Generic_x86_64/$f"
done
ls -la "$STAGE/android-Generic_x86_64/"

echo ">> [3/4] grub.cfg (títulos + entrada de diagnóstico vulkan_apex)"
CFG="$STAGE/boot/grub/grub.cfg"
python3 - "$CFG" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
for a,b in [
 ('menuentry "LineageOS 24.0 Live" {','menuentry "LineageOS 24.0 Live (KernelSU + Vulkan)" {'),
 ('menuentry "LineageOS 24.0 Live (Copy system to RAM)" {','menuentry "LineageOS 24.0 Live (Copy system to RAM, KernelSU + Vulkan)" {'),
 ('menuentry "LineageOS 24.0 Live (Debug)" {','menuentry "LineageOS 24.0 Live (Debug, KernelSU + Vulkan)" {'),
 ('menuentry "LineageOS 24.0 Live (Enable serial console)" {','menuentry "LineageOS 24.0 Live (Enable serial console, KernelSU + Vulkan)" {'),
 ('menuentry "LineageOS 24.0 Live (Enable suspend)" {','menuentry "LineageOS 24.0 Live (Enable suspend, KernelSU + Vulkan)" {'),
 ('menuentry "LineageOS 24.0 Live (Skip mounting firmware)" {','menuentry "LineageOS 24.0 Live (Skip mounting firmware, KernelSU + Vulkan)" {'),
 ('submenu "Advanced graphics options for LineageOS 24.0 Live" {','submenu "Advanced graphics options for LineageOS 24.0 Live (KernelSU + Vulkan)" {'),
]:
    assert a in s, a
    s=s.replace(a,b)
anchor='    menuentry "Force using Mesa llvmpipe graphics" {\n        boot_android_with_default_mount_options androidboot.graphics=llvmpipe\n    }\n'
assert anchor in s
s=s.replace(anchor, anchor+'    menuentry "Select Vulkan APEX: swiftshader (software Vulkan for diagnostics)" {\n        boot_android_with_default_mount_options androidboot.vulkan_apex=2\n    }\n')
open(p,'w').write(s)
PY

echo ">> [4/4] xorriso (opções idênticas às da original, capturadas via report_system_area)"
xorriso -as mkisofs \
  -V 'ISOIMAGE' \
  --modification-date='2026102016335700' \
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
rm -rf "$STAGE"
echo ">> pronta: $OUT"
ls -la "$OUT"

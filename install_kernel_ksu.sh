#!/usr/bin/env bash
# Instalação do kernel com KernelSU: cria os artefatos .ksu (kernel + vendor_dlkm
# + ramdisk) em /mnt/p7/android-Generic_x86_64/ e (opcional) entrada GRUB dedicada,
# SEM tocar no boot original ( rollback imediato).
#
# Pré-requisitos:
#   - kernel construído por build_kernel_ksu.sh (out/arch/x86/boot/bzImage)
#   - módulos instalados em modstaging/lib/modules
#   - imagens originais em /mnt/p7/android-Generic_x86_64/
#
# Uso:
#   sudo ./install_kernel_ksu.sh            # só gera artefatos .ksu
#   sudo ./install_kernel_ksu.sh --apply-boot  # também adiciona entrada GRUB
set -euo pipefail

BASE=/home/iris/android17/build/ksu
A=/mnt/p7/android-Generic_x86_64
KOUT=$BASE/out/arch/x86/boot/bzImage
MODS=$BASE/modstaging/lib/modules
PYTHON=/usr/bin/python3
EROFSDIR=/home/iris/android17/extracted/erofs-inst/bin
GRUBCFG=/boot/efi/EFI/android-system-generic-x86-64/grub.cfg

die(){ echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "rodar com sudo"
[ -f "$KOUT" ] || die "bzImage não encontrado: $KOUT"

echo ">> [1/4] kernel.ksu"
cp -f "$KOUT" "$A/kernel.ksu.new" || die "cópia do kernel falhou"
mv -f "$A/kernel.ksu.new" "$A/kernel.ksu"
file "$A/kernel.ksu" | sed 's/^/   /'

# =================== 2) vendor_dlkm.ksu.img ===================
echo ">> [2/4] vendor_dlkm (módulos)"
W=$(mktemp -d /tmp/kdlkm.XXXXXX)
$EROFSDIR/fsck.erofs --extract="$W/root" --force --preserve --xattrs \
    "$A/vendor_dlkm.img" >/dev/null || die "extract vendor_dlkm falhou"
echo "   .ko originais: $(find $W/root -name '*.ko*'|wc -l)"

MODBASE=$(ls -d "$MODS"/*/ 2>/dev/null | head -1); [ -n "$MODBASE" ] || die "sem modstaging"
find "$W/root/lib/modules" -name "*.ko" -delete 2>/dev/null || true
find "$MODBASE" -name "*.ko" | while read -r ko; do
  # vendor_dlkm original é FLAT: lib/modules/<nome>.ko
  out="$W/root/lib/modules/$(basename "$ko")"
  install -m 0644 "$ko" "$out"
done || die "cópia dos módulos falhou"
echo "   .ko novos:     $(find $W/root -name '*.ko'|wc -l)"

TS=$($EROFSDIR/dump.erofs -s "$A/vendor_dlkm.img" 2>/dev/null | awk '/Filesystem created/ {sub(/^Filesystem created: /,"");sub(/ [A-Z]{2,3}$/,"");print;exit}')
T=$(date -u -d "$TS" +%s 2>/dev/null || echo 0)
if [ "$T" -gt 0 ]; then
  $EROFSDIR/mkfs.erofs -zlz4 --mount-point=/vendor_dlkm --preserve-mtime -T "$T" \
    "$A/vendor_dlkm.ksu.img.new" "$W/root" || die "mkfs vendor_dlkm falhou"
else
  $EROFSDIR/mkfs.erofs -zlz4 --mount-point=/vendor_dlkm --preserve-mtime \
    "$A/vendor_dlkm.ksu.img.new" "$W/root" || die "mkfs vendor_dlkm falhou"
fi
V=$(mktemp -d /tmp/kvchk.XXXXXX); mount -o ro,loop "$A/vendor_dlkm.ksu.img.new" "$V"
echo "   sanity: $(find $V -name '*.ko*' 2>/dev/null|wc -l) .ko na imagem nova"
umount "$V"; rmdir "$V"
mv -f "$A/vendor_dlkm.ksu.img.new" "$A/vendor_dlkm.ksu.img"
rm -rf "$W"

# =================== 3) ramdisk-all-combined.ksu.img ===================
echo ">> [3/4] ramdisk (troca de lib/modules/*.ko)"
RD=$A/ramdisk-all-combined.ksu.img
W2=$(mktemp -d /tmp/krd.XXXXXX)
lz4 -d -q "$A/ramdisk-all-combined.img" "$W2/rd.cpio" || die "unpack ramdisk"
$PYTHON - "$W2/rd.cpio" "$MODBASE" <<'PY'
import sys, os
cpiopath, moddir = sys.argv[1], sys.argv[2]

data = open(cpiopath, "rb").read()
def fld(H,i): return int(H[6+8*i:6+8*(i+1)],16)

# rec = (hdr_off, ino, mode, uid, gid, nlink, mtime, size, name, data_off, newdata|None, is_trailer)
recs = []
i = 0
while True:
    i = data.find(b"070701", i)
    if i < 0: break
    H = data[i:i+110]
    if len(H) < 110: break
    try:
        ino, mode, uid, gid, nlink, mtime, size, namesize = \
            fld(H,0), fld(H,1), fld(H,2), fld(H,3), fld(H,4), fld(H,5), fld(H,6), fld(H,11)
    except ValueError:
        i += 1; continue
    nameoff = i + 110
    nameb = data[nameoff:nameoff+namesize]
    if len(nameb) < namesize or not nameb.endswith(b"\x00"): i += 1; continue
    name = nameb[:-1]
    start = (nameoff + namesize + 3)//4*4
    datoff = start
    is_trailer = (name == b"TRAILER!!!")
    recs.append(dict(h=i, ino=ino, mode=mode, uid=uid, gid=gid, nlink=nlink,
                     mtime=mtime, size=size, orig_size=size,
                     name=name, dat=datoff, newdata=None,
                     trailer=is_trailer))
    if is_trailer:
        i = datoff           # trailer sem dados; próxima pesquisa de magic a partir daqui
        continue
    i = datoff + ((size+3)//4)*4

all_kos = [r for r in recs if r["name"].startswith(b"lib/modules/") and r["name"].endswith(b".ko")]
print(f"   entradas no cpio: {len(recs)}  (!!!trailers: {sum(1 for r in recs if r['trailer'])})")
print(f"   módulos .ko no ramdisk: {len(all_kos)}")

# mapa basename -> caminho no build (modstaging usa lib/modules/7.2.0+/kernel/...)
MOD = {}
for dp, dn, fn in os.walk(moddir):
    for sf in fn:
        if sf.endswith(".ko"):
            MOD[sf] = os.path.join(dp, sf)

# módulos que viraram builtin no kernel novo (não existem mais como .ko)
BUILTIN = {b"ext4.ko", b"jbd2.ko", b"mbcache.ko", b"crc16.ko"}

replaced = 0; missing = []
for r in recs:
    nm = r["name"]
    if r["trailer"] or not (nm.startswith(b"lib/modules/") and nm.endswith(b".ko")):
        continue
    base = nm.rsplit(b"/", 1)[1].decode()
    full = MOD.get(base)
    if full is None:
        if base in {s.decode() for s in BUILTIN}:
            r["skip"] = True
            missing.append(nm.decode() + " (builtin→removido)")
        else:
            missing.append(nm.decode() + " (sem build novo, original mantido)")
        continue
    r["newdata"] = open(full, "rb").read()
    r["size"] = len(r["newdata"])
    replaced += 1
print(f"   substituídos: {replaced}   builtin removidos: {sum(1 for r in recs if r.get('skip'))}")
if missing:
    print("   ATENÇÃO módulos sem substituto:", ", ".join(missing[:8]), "..." if len(missing)>8 else "")

# re-serializa: cada entrada ocupa [h, h_do_próximo); skip descarta o intervalo inteiro
out = bytearray()
pos = 0
def pad4(b):
    if len(b) % 4: b += b"\x00" * (4 - len(b) % 4)
    return b

n = len(recs)
for idx in range(n):
    r = recs[idx]
    nxt = recs[idx + 1]["h"] if idx + 1 < n else len(data)
    if r.get("skip"):
        pos = nxt
        continue
    hdr_off = r["h"]
    nm = r["name"] + b"\x00"
    if hdr_off > pos:
        out += data[pos:hdr_off]           # gap (padding entre streams)
    if r["newdata"] is not None:
        body = r["newdata"]
    else:
        body = data[r["dat"]:r["dat"] + r["orig_size"]]
    size = len(body)
    # header: mantém o ORIGINAL byte-a-byte, sobrescreve só o campo size (field 6)
    H = bytearray(data[hdr_off:hdr_off + 110])
    H[6 + 48:6 + 56] = ("%08x" % (size & 0xFFFFFFFF)).encode()
    assert len(H) == 110, len(H)
    out += pad4(bytes(H) + nm)
    out += pad4(body)
    pos = nxt
out += data[pos:]
assert out[:6] == b"070701"
open(cpiopath + ".new", "wb").write(bytes(out))
print(f"   rd.cpio novo: {len(out)} bytes (antes: {len(data)})")
PY
# sanity no arquivo novo e recompressão (formato LEGACY, como o original do Android)
lz4 -l -q -9 "$W2/rd.cpio.new" "$W2/rd-new.lz4"
lz4 -d -q "$W2/rd-new.lz4" "$W2/verify.cpio" || die "recompressão lz4 inválida"
echo "   sanity final ramdisk: $(wc -c < "$W2/verify.cpio") bytes (== $(wc -c < "$W2/rd.cpio.new"))"
[ "$(wc -c < "$W2/verify.cpio")" = "$(wc -c < "$W2/rd.cpio.new")" ] || die "round-trip do ramdisk difere"
$PYTHON - "$W2/verify.cpio" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
def fld(H,i): return int(H[6+8*i:6+8*(i+1)],16)
i = 0; kos = 0; trailers = 0; entries = 0; bad = 0
while True:
    i = data.find(b"070701", i)
    if i < 0: break
    H = data[i:i+110]
    if len(H) < 110: bad += 1; break
    try: namesize = fld(H,11); size = fld(H,6)
    except ValueError: bad += 1; break
    nameoff = i+110
    nameb = data[nameoff:nameoff+namesize]
    if len(nameb) < namesize or not nameb.endswith(b"\x00"): bad += 1; break
    name = nameb[:-1]
    entries += 1
    if name == b"TRAILER!!!":
        trailers += 1; i = nameoff+namesize; continue
    start = (nameoff+namesize+3)//4*4
    if name.startswith(b"lib/modules/") and name.endswith(b".ko"): kos += 1
    i = start + ((size+3)//4)*4
print("   sanity: entradas=%d  .ko=%d  trailers=%d  bad=%d" % (entries, kos, trailers, bad))
PY
mv -f "$W2/rd-new.lz4" "$RD"
rm -rf "$W2"

# =================== 4) android_dir paralelo + GRUB entry ===================
# O generic_init (dynamic_mount_handler.cpp) casa imagens `*.img` do android_dir
# pelo nome do arquivo contra {product,system,system_dlkm,system_ext,odm,
# odm_dlkm,vendor,vendor_dlkm} — `vendor_dlkm.ksu.img` daria UNKNOWN e seria
# ignorada. Solução: dir paralelo com vendor_dlkm.ksu.img RENOMEADO para
# vendor_dlkm.img (hardlink) e symlinks para o resto (imagens + userdata dirs).
DIRKSU=$A-ksu
if [ "${1:-}" = "--apply-boot" ]; then
  echo ">> [4/4] android_dir paralelo + entrada GRUB"
  mkdir -p "$DIRKSU"
  for f in system.img vendor.img system_dlkm.img firmware.img; do
    [ -e "$DIRKSU/$f" ] || ln -s "../android-Generic_x86_64/$f" "$DIRKSU/$f"
  done
  for d in cache metadata userdata; do
    [ -e "$DIRKSU/$d" ] || ln -s "../android-Generic_x86_64/$d" "$DIRKSU/$d"
  done
  ln -f "$A/vendor_dlkm.ksu.img" "$DIRKSU/vendor_dlkm.img" 2>/dev/null \
    || cp -lf "$A/vendor_dlkm.ksu.img" "$DIRKSU/vendor_dlkm.img"
  grep -q "kernel.ksu" "$GRUBCFG" && echo "   já existe" || {
    XY=$(grep -n "^menuentry 'LineageOS 24.0 (dbg, persistent data)'" "$GRUBCFG" | head -1 | cut -d: -f1)
    [ -n "$XY" ] || die "entry base não encontrada no grub.cfg"
    ENDB=$(sed -n "${XY},\$p" "$GRUBCFG" | grep -n "^}" | head -1 | cut -d: -f1)
    [ -n "$ENDB" ] || die "fim da entry base não encontrado"
    BLOCK=$(sed -n "${XY},$((ENDB+XY-1))p" "$GRUBCFG")
    KSUENT=$(printf '%s' "$BLOCK" | sed \
      -e "s/LineageOS 24.0 (dbg, persistent data)/LineageOS 24.0 (KSU, persistent data)/" \
      -e "s| /android-Generic_x86_64/kernel | /android-Generic_x86_64/kernel.ksu |" \
      -e "s|/android-Generic_x86_64/ramdisk-all-combined.img|/android-Generic_x86_64/ramdisk-all-combined.ksu.img|" \
      -e "s|androidboot.android_dir=android-Generic_x86_64 |androidboot.android_dir=android-Generic_x86_64-ksu |")
    { head -c1 /dev/null; }
    { head -n "$((ENDB+XY-1))" "$GRUBCFG"; printf '%s\n' "$KSUENT"; tail -n "+$((ENDB+XY))" "$GRUBCFG"; } \
      > "$GRUBCFG.new" || die "falha ao gerar grub novo"
    mv -f "$GRUBCFG.new" "$GRUBCFG"
    echo "   entrada 'LineageOS 24.0 (KSU, persistent data)' adicionada ✓"
  }
else
  echo ">> [4/4] pulado (use --apply-boot para adicionar entrada GRUB)"
fi

echo
echo ">> Artifacts prontos:"
ls -la "$A"/kernel.ksu "$A"/vendor_dlkm.ksu.img "$A"/ramdisk-all-combined.ksu.img 2>/dev/null

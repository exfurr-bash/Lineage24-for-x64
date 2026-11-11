#!/usr/bin/env bash
# Build do kernel "exato" do Generic x86_64 (Linux 7.2.0+ android-mainline)
# com KernelSU integrado (builtin), para substituir o kernel da instalação
# em /dev/nvme0n1p7.
#
# Receita reproduzida do projeto (device tree mainline):
#   - fonte: android.googlesource.com/kernel/common, branch android-mainline,
#     pinado no commit que gerava "Linux version 7.2.0+" por volta de 2026-10-20
#   - patches LineageOS (topic mainline-kernel): vmwgfx ABGR8888,
#     HACK selinux permissive, revert virtio context (security/selinux/selinuxfs.c
#     e DRM — o HACK do selinux é essencial para androidboot.selinux=permissive)
#   - KernelSU v3.3.1 integrado in-source (drivers/kernelsu, CONFIG_KSU=y)
#   - fix x86_64 moderno: CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=y
#   - config: extraída do kernel instalado (extract-ikconfig) + deltas KSU
#   - compiler: clang distro (CC_VERSION_TEXT muda; aceitável) + rustc 1.93.1
#
# Uso:
#   ./build_kernel_ksu.sh            # build completo
#   ./build_kernel_ksu.sh 2>&1 | tee build.log
#
# Set before running if needed:
#   KSU_KERNEL_COMMIT=<sha>  # revision de android-mainline (default: env PinnedCommit embutido)
set -euo pipefail

# ============================== caminhos ==============================
BASE=/home/iris/android17/build/ksu
SRC=$BASE/kernel-mainline        # clone de android-mainline (googlesource)
KSUREPO=$BASE/KernelSU           # tiann/KernelSU @ v3.3.1
CFGDIR=$BASE/configs-extra       # fragments do device tree (pre-debian etc.)
DEBIAN=$BASE/debian-linux        # configs do debian (para gerar filtered)
PATCHES=$BASE/lineage-patches    # patch-423579/464426/496668
OUT=$BASE/out
MODSTAGE=$BASE/modstaging
REFCONFIG=$BASE/configs-extra/kernel-current.config  # config exata do kernel instalado
KERNEL_ARQ=/mnt/p7/android-Generic_x86_64/kernel # bzImage de referência

# ============================== pin do kernel ==============================
# Fonte oficial: release 20261020 do repo IzumiSenaSora/Generic_X86_64
# "Linux kernel: based on android-mainline v7.2.0 @ a2a0ccf4c105"
KSU_KERNEL_COMMIT="${KSU_KERNEL_COMMIT:-a2a0ccf4c10574fde950e554abffd9bdc9aec676}"

# ============================== opções KSU ==============================
#    CONFIG_KSU=y                            # builtin
#    CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=y
#    CONFIG_EXT4_FS=y                        # dependência de KSU=y (era m)
#
# CONFIG_EXT4_FS_SECURITY=y + EXT4_FS_POSIX_ACL=y (boot 3):
#   o antigo padrão de remoção /^CONFIG_EXT4_FS/ (sem boundary) apagava também
#   CONFIG_EXT4_FS_SECURITY / _POSIX_ACL / etc; o olddefconfig as deixava no
#   default (=n — não têm default-y). Sem EXT4_FS_SECURITY o ext4 não registra
#   handler de xattr de segurança → no mount do payload ext4 dos APEXes o hook
#   SELinux (sb_check_xattr_support) recebe EOPNOTSUPP do getxattr, cai no
#   fallback genfs que falha (política SELinux ainda não carregada no
#   bootstrap) e devolve -EOPNOTSUPP ao mount() → apexd-bootstrap:
#   "Mounting failed for package …" → reboot bootstrap-apexd-failed.
#
# CONFIG_X86_KERNEL_IBT=n (boot 1):
#   KSU faz chamadas indiretas a endereços resolvidos via kallsyms; com IBT=y o
#   objtool sela (endbr64->nop) funções que não são alvo indireto por relocação
#   C — a indireção via tabela kallsyms é invisível ao objtool → #CP no
#   initcall.
#
# CONFIG_MODULE_ALLOW_BTF_MISMATCH=y (boot 2):
#   módulos com .BTF divergente/inválido fazem o validador BTF ABORTAR o insmod
#   (failed to validate module [X] BTF: -22 → EINVAL → generic_init sem block
#   device). Com =y a falha vira pr_warn_once e o módulo carrega sem BTF.
#   Exclusiva com DEBUG_INFO_BTF_MODULES=n (alternativa: módulos do tree nascem
#   sem .BTF; esta cobre também .ko prebuilt de outro build). Artefatos atuais:
#   .BTF/.BTF.ext removidos via objcopy (não dependem disto).
# SOMENTE linhas CONFIG_*: nada de comentários/as aqui dentro (quebrar o parse).
CONFIG_APPEND="
CONFIG_KSU=y
CONFIG_KSU_DEBUG=n
CONFIG_KSU_DISABLE_MANAGER=n
CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=y
CONFIG_EXT4_FS=y
CONFIG_EXT4_FS_SECURITY=y
CONFIG_EXT4_FS_POSIX_ACL=y
CONFIG_X86_KERNEL_IBT=n
CONFIG_MODULE_ALLOW_BTF_MISMATCH=y
"

JOBS=${JOBS:-$(nproc)}
# segurança de memória: clang + 7GB de RAM matou com paralelismo alto SEM swap
# (OOM). Com swap folgado (≥32 GB) o OOM vira thrash em vez de morte — permite
# subir até 12 jobs (nproc=12); sem swap folgado, mantém o cap de 4.
MEMGB=$(free -g | awk '/^Mem/ {print $2}')
SWAPGB=$(free -g | awk '/^Swap/ {print $2}')
if [ "$MEMGB" -lt 12 ]; then
  if [ "$SWAPGB" -ge 32 ]; then
    [ "$JOBS" -gt 12 ] && JOBS=12
  else
    [ "$JOBS" -gt 4 ] && JOBS=4
  fi
fi
echo "    JOBS=$JOBS (mem $MEMGB GB, swap $SWAPGB GB)"

die(){ echo "ERROR: $*" >&2; exit 1; }

[ -d "$SRC" ] || die "sem $SRC (clone android-mainline)"
[ -d "$KSUREPO" ] || die "sem $KSUREPO (clone KernelSU v3.3.1)"
[ -f "$REFCONFIG" ] || die "sem config de referência $REFCONFIG"

echo "[1/7] pin do commit $KSU_KERNEL_COMMIT ..."
cd "$SRC"
git checkout -q --detach "$KSU_KERNEL_COMMIT"
MVER=$(sed -n '3p;4p;5p;6p' Makefile | head -4 | tr -d '\n')
echo "    Makefile: $MVER"

echo "[2/7] patches LineageOS (topic mainline-kernel) ..."
for p in "$PATCHES"/patch-*.diff; do
  if git apply --check "$p" 2>/dev/null; then
    git apply "$p"; echo "    aplicado: $(basename "$p")"
  elif git apply --reverse --check "$p" 2>/dev/null; then
    echo "    já aplicado: $(basename "$p")"
  else
    echo "    NÃO aplica direto: $(basename "$p") (fallback manual abaixo p/ vmwgfx)"
  fi
done
# fallback manual p/ 423579 (o contexto mudou no 7.2/XRGB8888): numa árvore em que
# ABGR8888 ainda não estiver no array, insere após XRGB1555
if ! grep -q "DRM_FORMAT_ABGR8888" drivers/gpu/drm/vmwgfx/vmwgfx_kms.h 2>/dev/null; then
  perl -0pi -e 's/(DRM_FORMAT_XRGB1555,\n\};)/\tDRM_FORMAT_ABGR8888,\n$1/' \
    drivers/gpu/drm/vmwgfx/vmwgfx_kms.h 2>/dev/null && echo "    ABGR8888 inserido manualmente"
fi

echo "[3/7] integração KernelSU (drivers/kernelsu) ..."
DRIVERS="$SRC/drivers"
rm -f "$DRIVERS/kernelsu"
ln -sf "$KSUREPO/kernel" "$DRIVERS/kernelsu"
grep -q "kernelsu/" "$DRIVERS/Makefile" || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DRIVERS/Makefile"
grep -q 'drivers/kernelsu/Kconfig' "$DRIVERS/Kconfig" || {
  printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$DRIVERS/Kconfig"
}
echo "    KernelSU integrado ($(cd $KSUREPO && git describe --tags --always 2>/dev/null || echo v3.3.1))"

echo "[4/7] .config a partir do kernel instalado + deltas KSU ..."
mkdir -p "$OUT"
cp "$REFCONFIG" "$OUT/.config"
# remove a linha de CC_VERSION_TEXT (deixa o build registrar o clang da máquina)
sed -i '/CONFIG_CC_VERSION_TEXT=/d' "$OUT/.config"
# aplica deltas KSU (idempotente): remove valores/entradas anteriores e reescreve
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in "#"*) continue ;; esac   # comentários não são config
  key="${line%%=*}"
  # match EXATO (boot 3): o padrão antigo /^CONFIG_EXT4_FS/ sem boundary apagava
  # também CONFIG_EXT4_FS_SECURITY / _POSIX_ACL / etc — e o olddefconfig as
  # deixava no default (=n; não têm "default y") → mount EOPNOTSUPP nos payloads
  # ext4 dos APEXes → bootstrap-apexd-failed.
  sed -i "/^${key}=/d;/^# ${key#CONFIG_} is not set\$/d" "$OUT/.config"
  echo "$line" >> "$OUT/.config"
done <<< "$CONFIG_APPEND"
RUSTBINDIR="$HOME/.rustup/toolchains/1.93.1-x86_64-unknown-linux-gnu/bin"
[ -x "$RUSTBINDIR/rustc" ] || die "rustc 1.93.1 ausente (rustup toolchain install 1.93.1)"
export PATH="$RUSTBINDIR:$PATH"
RUSTMAKES="RUSTC=rustc"
make O="$OUT" LLVM=1 CC=clang "$RUSTMAKES" olddefconfig >/dev/null 2>&1 || {
  # AOSP android-mainline: Kconfig:37 exige $(KCONFIG_EXT_PREFIX)Kconfig.ext
  # (setado pelo build Soong/LineageOS). Em standalone, um stub vazio basta —
  # todos os valores do ext config já estão "congelados" na config extraída.
  [ -f "$SRC/Kconfig.ext" ] || : > "$SRC/Kconfig.ext"
  # e exporta prefixo vazio para o parse não tentar outro caminho
  KCONFIG_EXT_PREFIX= make O="$OUT" LLVM=1 CC=clang "$RUSTMAKES" olddefconfig >/dev/null
}
# guardas pós-olddefconfig: os dois deltas Rust NÃO podem sumir
grep -q "^CONFIG_RUST=y$" "$OUT/.config" || die "CONFIG_RUST caiu — rustc detectado não suportado pelo tree"
grep -q "^CONFIG_AX88796B_RUST_PHY=y$" "$OUT/.config" || die "AX88796B_RUST_PHY sumiu"
grep -q "^CONFIG_AMCC_QT2025_PHY=m$" "$OUT/.config" || die "AMCC_QT2025_PHY sumiu"
echo "    .config OK. Deltas esperados: KSU, KSU_X86_PATCH_SYSCALL_DISPATCHER, EXT4_FS, EXT4_FS_SECURITY, EXT4_FS_POSIX_ACL, IBT=n, ALLOW_BTF_MISMATCH=y, CC_VERSION_TEXT"
grep -q '^# CONFIG_X86_KERNEL_IBT is not set$' "$OUT/.config" \
  || die "CONFIG_X86_KERNEL_IBT não ficou desligado (IBT y → #CP no initcall do KSU)"
grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT/.config" \
  || die "CONFIG_MODULE_ALLOW_BTF_MISMATCH não ficou ligado (BTF de módulo divergente → insmod EINVAL → sem block device)"
grep -q '^CONFIG_EXT4_FS_SECURITY=y$' "$OUT/.config" \
  || die "EXT4_FS_SECURITY sumiu (sem xattr selinux no ext4 → mount de payload APEX retorna EOPNOTSUPP → bootstrap-apexd-failed)"
grep -q '^CONFIG_EXT4_FS_POSIX_ACL=y$' "$OUT/.config" \
  || die "EXT4_FS_POSIX_ACL sumiu (regressão vs stock)"

echo "[6/7] build bzImage (e modules) com clang ..."
PATH="$HOME/.rustup/toolchains/1.93.1-x86_64-unknown-linux-gnu/bin:$PATH" \
make -C "$SRC" O="$OUT" LLVM=1 CC=clang -j"$JOBS" bzImage \
  RUSTC="rustc" \
  2>&1 | tail -12

echo "[7/7] modules_install (para repack de vendor_dlkm + ramdisk) ..."
rm -rf "$MODSTAGE"
make -C "$SRC" O="$OUT" LLVM=1 CC=clang -j"$JOBS" modules \
  RUSTC="rustc" 2>&1 | tail -5
make -C "$SRC" O="$OUT" LLVM=1 CC=clang \
  INSTALL_MOD_PATH="$MODSTAGE" INSTALL_MOD_STRIP=1 \
  RUSTC="rustc" modules_install 2>&1 | tail -5

KOUT="$OUT/arch/x86/boot/bzImage"
[ -f "$KOUT" ] || die "bzImage não foi gerado"

echo "=== verificação ==="
file "$KOUT" | grep -o "version [0-9.]*+* " || true
file "$KOUT"
"$SRC/scripts/extract-ikconfig" "$KOUT" | grep -E "CONFIG_KSU|KSU_X86|EXT4_FS=|EXT4_FS_SECURITY|EXT4_FS_POSIX_ACL|MODULE_ALLOW_BTF|MODULE_SIG|IODEBUG" || true
nl="$(file "$KOUT" | sed -n 's/.*version \([^ ]*\).*/\1/p')"
echo "==================================================="
echo "KERNEL OK → $KOUT (versão: $nl)"
echo "modules  → $MODSTAGE/lib/modules/"
echo "próximo: scripts de repack vendor_dlkm.img e ramdisk + entrada GRUB"

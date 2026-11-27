#!/usr/bin/env bash
# Compila o kernel android-mainline 7.2.0+ com KernelSU builtin.
#
# Fonte: android.googlesource.com/kernel/common, pinado em
# config/sources.lock (KERNEL_COMMIT). KernelSU na tag KSU_TAG.
#
# Uso:
#   scripts/build_kernel_ksu.sh
#   scripts/build_kernel_ksu.sh 2>&1 | tee logs/build.log
#   JOBS=8 scripts/build_kernel_ksu.sh
#
# Variáveis relevantes (config.env): KERNEL_SRC, KSU_REPO, PATCHES_DIR,
# REFCONFIG, OUT_DIR, MODSTAGE_DIR, JOBS, RUST_TOOLCHAIN, KVER.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"
enable_err_trap

ALLOW_KSU_MISMATCH=0
STRICT_CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --allow-ksu-mismatch) ALLOW_KSU_MISMATCH=1 ;;
    --strict-clean) STRICT_CLEAN=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "opção desconhecida: $arg" ;;
  esac
done

KERNEL_COMMIT=${KERNEL_COMMIT:-$(lock_get KERNEL_COMMIT)}
[ -n "$KERNEL_COMMIT" ] || die "KERNEL_COMMIT ausente em $SOURCES_LOCK"
RUST_TOOLCHAIN=${RUST_TOOLCHAIN:-1.93.1}
JOBS=${JOBS:-$(nproc)}

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

die_cfg() { die "$1"; }

section "pré-requisitos"
require_cmd git make clang ld.lld bc flex bison python3
[ -d "$KERNEL_SRC" ] || die "sem KERNEL_SRC=$KERNEL_SRC (clone de $KERNEL_REPO)"
[ -d "$KSU_REPO" ] || die "sem KSU_REPO=$KSU_REPO (clone de $KSU_REPO_URL)"
[ -f "$REFCONFIG" ] || die "sem REFCONFIG=$REFCONFIG"
mkdir -p "$OUT_DIR" "$MODSTAGE_DIR"
check_free_space "$OUT_DIR" 16

RUSTBIN=""
if command -v rustup >/dev/null 2>&1; then
  RUSTBIN=$(rustup which --toolchain "$RUST_TOOLCHAIN" rustc 2>/dev/null || true)
fi
[ -n "$RUSTBIN" ] || RUSTBIN=$(command -v rustc 2>/dev/null || true)
[ -n "$RUSTBIN" ] || die "rustc ausente (instale a toolchain $RUST_TOOLCHAIN: scripts/bootstrap.sh --with-rust)"
RUSTBINDIR=$(dirname "$RUSTBIN")
"$RUSTBIN" --version | sed 's/^/   /'

# Guarda de memória: clang com 7 GB sem swap OOM-killou com paralelismo alto.
MEMGB=$(free -g | awk '/^Mem/ {print $2}')
SWAPGB=$(free -g | awk '/^Swap/ {print $2}')
if [ "$MEMGB" -lt 12 ]; then
  if [ "$SWAPGB" -ge 32 ]; then
    [ "$JOBS" -gt 12 ] && JOBS=12
  else
    [ "$JOBS" -gt 4 ] && JOBS=4
  fi
fi
log "JOBS=$JOBS (RAM ${MEMGB} GB, swap ${SWAPGB} GB)"

section "[1/7] pin do kernel $KERNEL_COMMIT"
cd "$KERNEL_SRC"
if ! git cat-file -e "$KERNEL_COMMIT^{commit}" 2>/dev/null; then
  die "commit $KERNEL_COMMIT não está no clone; rode: git -C $KERNEL_SRC fetch origin $KERNEL_COMMIT"
fi
if [ -n "$(git status --porcelain)" ]; then
  if [ "$STRICT_CLEAN" = 1 ]; then
    die "árvore $KERNEL_SRC suja (--strict-clean); limpe/commit antes"
  fi
  warn "árvore $KERNEL_SRC suja (patches/symlink de execuções anteriores); continuando"
fi
git checkout -q --detach "$KERNEL_COMMIT"
MVER=$(sed -n '3p;4p;5p;6p' Makefile | tr -d '\n')
log "Makefile: $MVER"

section "[2/7] patches LineageOS (topic mainline-kernel)"
for p in "$PATCHES_DIR"/patch-*.diff; do
  [ -e "$p" ] || continue
  if git apply --check "$p" 2>/dev/null; then
    git apply "$p"; ok "aplicado: $(basename "$p")"
  elif git apply --reverse --check "$p" 2>/dev/null; then
    ok "já aplicado: $(basename "$p")"
  else
    warn "não aplica direto: $(basename "$p") (fallback manual para vmwgfx)"
  fi
done
if ! grep -q "DRM_FORMAT_ABGR8888" drivers/gpu/drm/vmwgfx/vmwgfx_kms.h 2>/dev/null; then
  perl -0pi -e 's/(DRM_FORMAT_XRGB1555,\n\};)/\tDRM_FORMAT_ABGR8888,\n$1/' \
    drivers/gpu/drm/vmwgfx/vmwgfx_kms.h 2>/dev/null \
    && ok "ABGR8888 inserido manualmente (vmwgfx)"
fi

section "[3/7] integração KernelSU"
KSU_TAG_ACTUAL=$(git -C "$KSU_REPO" describe --tags --exact-match 2>/dev/null || true)
if [ "$KSU_TAG_ACTUAL" != "$KSU_TAG" ]; then
  if [ "$ALLOW_KSU_MISMATCH" = 1 ]; then
    warn "KernelSU em '$KSU_TAG_ACTUAL' (esperado $KSU_TAG); seguindo por --allow-ksu-mismatch"
  else
    die "KernelSU em '$KSU_TAG_ACTUAL' (esperado $KSU_TAG); faça checkout da tag ou use --allow-ksu-mismatch"
  fi
fi
DRIVERS="$KERNEL_SRC/drivers"
rm -f "$DRIVERS/kernelsu"
ln -sf "$KSU_REPO/kernel" "$DRIVERS/kernelsu"
# shellcheck disable=SC2016  # $(CONFIG_KSU) é sintaxe do Makefile, não do shell
grep -q "kernelsu/" "$DRIVERS/Makefile" || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DRIVERS/Makefile"
grep -q 'drivers/kernelsu/Kconfig' "$DRIVERS/Kconfig" || \
  printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$DRIVERS/Kconfig"
ok "KernelSU integrado ($KSU_TAG)"

section "[4/7] .config a partir do kernel instalado + deltas KSU"
mkdir -p "$OUT_DIR"
cp "$REFCONFIG" "$OUT_DIR/.config"
sed -i '/CONFIG_CC_VERSION_TEXT=/d' "$OUT_DIR/.config"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in "#"*) continue ;; esac
  key="${line%%=*}"
  # match EXATO: um padrão sem boundary apagava CONFIG_EXT4_FS_SECURITY/_POSIX_ACL
  # (boot 3) — e o olddefconfig os deixava =n, quebrando o mount dos APEXes.
  sed -i "/^${key}=/d;/^# ${key} is not set\$/d" "$OUT_DIR/.config"
  printf '%s\n' "$line" >> "$OUT_DIR/.config"
done <<< "$CONFIG_APPEND"

KCONFIG_EXT_CREATED=0
cleanup_kconfig_ext() {
  if [ "$KCONFIG_EXT_CREATED" = 1 ]; then rm -f "$KERNEL_SRC/Kconfig.ext"; fi
  _cleanup_tmpdirs
}
trap cleanup_kconfig_ext EXIT

export PATH="$RUSTBINDIR:$PATH"
make O="$OUT_DIR" LLVM=1 CC=clang RUSTC=rustc olddefconfig >/dev/null 2>&1 || {
  [ -f "$KERNEL_SRC/Kconfig.ext" ] || { : > "$KERNEL_SRC/Kconfig.ext"; KCONFIG_EXT_CREATED=1; }
  KCONFIG_EXT_PREFIX='' make O="$OUT_DIR" LLVM=1 CC=clang RUSTC=rustc olddefconfig >/dev/null
}

section "[5/7] guardas de configuração"
grep -q "^CONFIG_RUST=y$" "$OUT_DIR/.config" || die "CONFIG_RUST caiu — rustc detectado não suportado pelo tree"
grep -q "^CONFIG_AX88796B_RUST_PHY=y$" "$OUT_DIR/.config" || die "AX88796B_RUST_PHY sumiu"
grep -q "^CONFIG_AMCC_QT2025_PHY=m$" "$OUT_DIR/.config" || die "AMCC_QT2025_PHY sumiu"
grep -q '^# CONFIG_X86_KERNEL_IBT is not set$' "$OUT_DIR/.config" \
  || die "X86_KERNEL_IBT não ficou desligado (IBT=y → #CP no initcall do KSU)"
grep -q '^CONFIG_MODULE_ALLOW_BTF_MISMATCH=y$' "$OUT_DIR/.config" \
  || die "MODULE_ALLOW_BTF_MISMATCH não ficou ligado (BTF divergente → insmod EINVAL)"
grep -q '^CONFIG_EXT4_FS_SECURITY=y$' "$OUT_DIR/.config" \
  || die "EXT4_FS_SECURITY sumiu (mount de payload APEX → EOPNOTSUPP)"
grep -q '^CONFIG_EXT4_FS_POSIX_ACL=y$' "$OUT_DIR/.config" \
  || die "EXT4_FS_POSIX_ACL sumiu (regressão vs stock)"
ok ".config OK (KSU, X86_PATCH, EXT4, IBT=n, BTF_MISMATCH, Rust)"

section "[6/7] build bzImage"
make -C "$KERNEL_SRC" O="$OUT_DIR" LLVM=1 CC=clang -j"$JOBS" bzImage RUSTC=rustc 2>&1 | tail -12
KOUT_BUILT=$OUT_DIR/arch/x86/boot/bzImage
[ -f "$KOUT_BUILT" ] || die "bzImage não foi gerado"

section "[7/7] modules + modules_install"
rm -rf "$MODSTAGE_DIR"
make -C "$KERNEL_SRC" O="$OUT_DIR" LLVM=1 CC=clang -j"$JOBS" modules RUSTC=rustc 2>&1 | tail -5
make -C "$KERNEL_SRC" O="$OUT_DIR" LLVM=1 CC=clang \
  INSTALL_MOD_PATH="$MODSTAGE_DIR" INSTALL_MOD_STRIP=1 \
  RUSTC=rustc modules_install 2>&1 | tail -5

section "verificação"
file "$KOUT_BUILT"
"$KERNEL_SRC/scripts/extract-ikconfig" "$KOUT_BUILT" \
  | grep -E 'CONFIG_KSU|KSU_X86|EXT4_FS=|EXT4_FS_SECURITY|EXT4_FS_POSIX_ACL|MODULE_ALLOW_BTF|MODULE_SIG' || true
KVER_ACTUAL=$(kernel_version_of "$KOUT_BUILT")
ok "KERNEL OK → $KOUT_BUILT (versão: $KVER_ACTUAL)"
ok "modules → $MODSTAGE_DIR/lib/modules/"
log "próximo: sudo scripts/install_kernel_ksu.sh --apply-boot"

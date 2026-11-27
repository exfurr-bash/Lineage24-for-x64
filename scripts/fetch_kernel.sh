#!/usr/bin/env bash
# Prepara as fontes do kernel (AOSP android-mainline) e do KernelSU.
#
# - kernel/common em KERNEL_COMMIT (config/sources.lock)
# - KernelSU na tag KSU_TAG
# - refconfig extraída do kernel stock (extract-ikconfig) se ainda não existir
# - diretório de patches LineageOS (opcional; vazio por padrão)
#
# Uso:
#   scripts/fetch_kernel.sh                 # kernel + KSU + refconfig
#   scripts/fetch_kernel.sh --kernel-only
#   scripts/fetch_kernel.sh --ksu-only
#   scripts/fetch_kernel.sh --force         # refaz checkout mesmo sujo
#
# Nada é compilado aqui. Próximo passo: make kernel.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"
enable_err_trap

KERNEL_ONLY=0
KSU_ONLY=0
FORCE=0
NO_REF=0

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }
for arg in "$@"; do
  case "$arg" in
    --kernel-only) KERNEL_ONLY=1 ;;
    --ksu-only) KSU_ONLY=1 ;;
    --no-refconfig) NO_REF=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "opção desconhecida: $arg" ;;
  esac
done

lock_require KERNEL_REPO KERNEL_COMMIT KSU_REPO_URL KSU_TAG KSU_COMMIT
KERNEL_REPO=${KERNEL_REPO:-$(lock_get KERNEL_REPO)}
KERNEL_COMMIT=${KERNEL_COMMIT:-$(lock_get KERNEL_COMMIT)}
KSU_REPO_URL=${KSU_REPO_URL:-$(lock_get KSU_REPO_URL)}
KSU_TAG=${KSU_TAG:-$(lock_get KSU_TAG)}
KSU_COMMIT=${KSU_COMMIT:-$(lock_get KSU_COMMIT)}
[ "$KERNEL_ONLY" = 1 ] && [ "$KSU_ONLY" = 1 ] && die "use apenas um de --kernel-only/--ksu-only"

fetch_kernel() {
  section "kernel: $KERNEL_REPO @ $KERNEL_COMMIT"
  if [ ! -d "$KERNEL_SRC/.git" ]; then
    log "clone parcial (blobs sob demanda) em $KERNEL_SRC"
    mkdir -p "$(dirname "$KERNEL_SRC")"
    git clone --filter=blob:none --no-checkout "$KERNEL_REPO" "$KERNEL_SRC"
  fi
  if ! git -C "$KERNEL_SRC" cat-file -e "$KERNEL_COMMIT^{commit}" 2>/dev/null; then
    log "buscando commit pinado"
    if ! git -C "$KERNEL_SRC" fetch --depth=1 origin "$KERNEL_COMMIT"; then
      warn "fetch por SHA falhou; tentando fetch da branch padrão"
      git -C "$KERNEL_SRC" fetch --filter=blob:none origin
    fi
  fi
  git -C "$KERNEL_SRC" cat-file -e "$KERNEL_COMMIT^{commit}" \
    || die "commit $KERNEL_COMMIT não encontrado em $KERNEL_SRC"
  if [ -n "$(git -C "$KERNEL_SRC" status --porcelain)" ]; then
    if [ "$FORCE" = 1 ]; then
      warn "--force: descartando alterações locais em $KERNEL_SRC"
      git -C "$KERNEL_SRC" reset --hard -q
      git -C "$KERNEL_SRC" clean -fdq -e .config -e '*.orig'
    else
      die "árvore $KERNEL_SRC suja; use --force ou limpe manualmente"
    fi
  fi
  git -C "$KERNEL_SRC" checkout -q --detach "$KERNEL_COMMIT"
  ok "kernel em $(git -C "$KERNEL_SRC" rev-parse --short HEAD)"
}

fetch_ksu() {
  local want tag_commit
  want=$(lock_get KSU_COMMIT)
  section "KernelSU: $KSU_REPO_URL @ $KSU_TAG ($want)"
  if [ ! -d "$KSU_REPO/.git" ]; then
    mkdir -p "$(dirname "$KSU_REPO")"
    git clone --depth=1 --filter=blob:none --no-checkout \
      --branch "$KSU_TAG" "$KSU_REPO_URL" "$KSU_REPO"
  fi
  git -C "$KSU_REPO" fetch --depth=1 origin \
    "refs/tags/$KSU_TAG:refs/tags/$KSU_TAG" \
    || die "não consegui buscar a tag $KSU_TAG em $KSU_REPO_URL"
  tag_commit=$(git -C "$KSU_REPO" rev-parse "$KSU_TAG^{commit}")
  [ "$tag_commit" = "$want" ] \
    || die "tag $KSU_TAG aponta para $tag_commit; lock exige $want"
  git -C "$KSU_REPO" checkout -q --detach "$want" \
    || die "não consegui fazer checkout do commit pinado $want"
  ok "KernelSU em $(git -C "$KSU_REPO" rev-parse --short HEAD)"
}

fetch_refconfig() {
  [ "$NO_REF" = 1 ] && { warn "refconfig não gerada (--no-refconfig)"; return 0; }
  if [ -s "$REFCONFIG" ]; then
    ok "refconfig já existe: $REFCONFIG"
    return 0
  fi
  local stock=$ANDROID_DIR/kernel
  [ -f "$stock" ] || stock=$ANDROID_DIR/kernel.ksu
  if [ ! -f "$stock" ]; then
    warn "kernel stock ausente em $ANDROID_DIR; refconfig não gerada"
    warn "rode 'make fetch' antes, ou defina REFCONFIG em config.env"
    return 0
  fi
  [ -x "$KERNEL_SRC/scripts/extract-ikconfig" ] \
    || die "sem $KERNEL_SRC/scripts/extract-ikconfig (rode o fetch do kernel primeiro)"
  mkdir -p "$(dirname "$REFCONFIG")"
  if "$KERNEL_SRC/scripts/extract-ikconfig" "$stock" > "$REFCONFIG.tmp" 2>/dev/null \
      && grep -q '^CONFIG_' "$REFCONFIG.tmp"; then
    mv -f "$REFCONFIG.tmp" "$REFCONFIG"
    ok "refconfig extraída do kernel stock: $REFCONFIG"
  else
    rm -f "$REFCONFIG.tmp"
    warn "não consegui extrair CONFIG_* de $stock; forneça REFCONFIG manualmente"
  fi
}

if [ "$KSU_ONLY" = 0 ]; then fetch_kernel; fi
if [ "$KERNEL_ONLY" = 0 ]; then fetch_ksu; fi
mkdir -p "$PATCHES_DIR"
if [ -z "$(find "$PATCHES_DIR" -maxdepth 1 -name 'patch-*.diff' -print -quit 2>/dev/null)" ]; then
  warn "sem patches LineageOS em $PATCHES_DIR (opcional; o build segue sem eles)"
fi
if [ "$KSU_ONLY" = 0 ]; then fetch_refconfig; fi

section "fontes do kernel prontas"
cat <<EOF
KERNEL_SRC=$KERNEL_SRC
KSU_REPO=$KSU_REPO
REFCONFIG=$REFCONFIG
PATCHES_DIR=$PATCHES_DIR
Próximo passo: make kernel
EOF

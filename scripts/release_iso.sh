#!/usr/bin/env bash
# Prepara (e opcionalmente publica) uma ISO como assets de release.
#
# GitHub limita assets a 2 GiB; a ISO tem ~3,2 GiB. O script divide em partes
# alfabéticas (`_aa`, `_ab`, ...) e gera `sha256sums.txt`, no mesmo esquema
# dos releases oficiais.
#
# Uso:
#   scripts/release_iso.sh --iso dist/foo.iso                 # só prepara
#   scripts/release_iso.sh --iso dist/foo.iso --upload        # gh release
#   scripts/release_iso.sh --iso dist/foo.iso --tag minha-tag --notes-file notas.md
#
# A variante GApps NÃO é publicada por padrão (--allow-gapps para liberar):
# os apps Google não são cobertos pela GPL e a redistribuição é de sua
# responsabilidade.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"
enable_err_trap

ISO=""
TAG=""
NOTES=""
UPLOAD=0
ALLOW_GAPPS=0
PART_SIZE=${PART_SIZE:-1900M}
OUTDIR=""

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO=${2:?}; shift ;;
    --tag) TAG=${2:?}; shift ;;
    --notes-file) NOTES=${2:?}; shift ;;
    --outdir) OUTDIR=${2:?}; shift ;;
    --part-size) PART_SIZE=${2:?}; shift ;;
    --upload) UPLOAD=1 ;;
    --allow-gapps) ALLOW_GAPPS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "opção desconhecida: $1" ;;
  esac
  shift
done

[ -n "$ISO" ] && [ -f "$ISO" ] || die "ISO não encontrada (use --iso)"
case "$ISO" in
  *gapps*)
    [ "$ALLOW_GAPPS" = 1 ] || die "ISO GApps: use --allow-gapps se for realmente publicar (apps Google não são GPL)"
    ;;
esac

base=$(basename "$ISO" .iso)
[ -n "$TAG" ] || TAG=$base
[ -n "$OUTDIR" ] || OUTDIR=$DIST_DIR/release/$TAG
mkdir -p "$OUTDIR"
[ -z "$(find "$OUTDIR" -mindepth 1 -maxdepth 1 -print -quit)" ] \
  || die "diretório de saída não está vazio; escolha outro --outdir: $OUTDIR"

PART_BYTES=$(numfmt --from=iec "$PART_SIZE" 2>/dev/null) \
  || die "tamanho de parte inválido: $PART_SIZE"
[ "$PART_BYTES" -gt 0 ] && [ "$PART_BYTES" -lt 2147483648 ] \
  || die "cada parte deve ter menos de 2 GiB: $PART_SIZE"

section "checksums"
( cd "$(dirname "$ISO")" && sha256sum "$(basename "$ISO")" ) > "$OUTDIR/$base.iso.sha256"
assets=("$OUTDIR/$base.iso.sha256")
if [ -f "$WORKSPACE_DIR/SOURCES.json" ]; then
  cp -a "$WORKSPACE_DIR/SOURCES.json" "$OUTDIR/SOURCES.json"
  assets+=("$OUTDIR/SOURCES.json")
fi

section "dividindo em partes de $PART_SIZE"
# split alfabético gera sufixos aa, ab, ac...
split -b "$PART_BYTES" -a 2 "$ISO" "$OUTDIR/$base.iso_"
parts=( "$OUTDIR/$base.iso_"* )
[ -f "${parts[0]}" ] || die "split não gerou partes"
log "${#parts[@]} parte(s)"
assets+=("${parts[@]}")

section "sha256sums.txt"
(
  cd "$OUTDIR"
  cat "$base.iso.sha256"
  sha256sum "$base".iso_*
) > "$OUTDIR/sha256sums.txt"
cat "$OUTDIR/sha256sums.txt"

cat > "$OUTDIR/README.txt" <<EOF
$base

ISO live do projeto Lineage24-for-x64.
Base: $BASE_RELEASE.
Junte as partes antes de usar:
  cat $base.iso_* > $base.iso
  sha256sum -c sha256sums.txt
Teste com: scripts/test_qemu.sh --iso $base.iso
EOF
assets+=("$OUTDIR/sha256sums.txt" "$OUTDIR/README.txt")

section "assets"
ls -lh "$OUTDIR"

if [ "$UPLOAD" = 0 ]; then
  ok "pronto (não publicado). Para publicar: scripts/release_iso.sh --iso $ISO --tag $TAG --upload"
  exit 0
fi

require_cmd gh
gh auth status >/dev/null 2>&1 || die "gh não autenticado (gh auth login)"
if gh release view "$TAG" >/dev/null 2>&1; then
  log "release $TAG já existe; enviando/atualizando assets com --clobber"
  gh release upload "$TAG" "${assets[@]}" --clobber
else
  [ -n "$NOTES" ] && [ -f "$NOTES" ] || NOTES=""
  if [ -n "$NOTES" ]; then
    gh release create "$TAG" "${assets[@]}" --title "$base" --notes-file "$NOTES"
  else
    gh release create "$TAG" "${assets[@]}" --title "$base" --notes "ISO live: $base (base $BASE_RELEASE)"
  fi
fi
ok "release publicado: $TAG"

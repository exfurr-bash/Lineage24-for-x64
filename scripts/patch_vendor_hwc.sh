#!/usr/bin/env bash
# Wrapper compatível: aplica o fix de frame-rate no vendor.img (issue #3).
#
# Uso:
#   sudo scripts/patch_vendor_hwc.sh [vendor.img] [--out vendor.ksu.img]
#
# Sem argumento usa $ANDROID_DIR/vendor.img e grava em vendor.ksu.img.
# A imagem de entrada não é sobrescrita.
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"

BASE=$ANDROID_DIR/vendor.img
OUT=""
while [ $# -gt 0 ]; do
  a=$1
  case "$a" in
    --base) BASE=${2:?}; shift ;;
    --out) OUT=${2:?}; shift ;;
    -h|--help)
      echo "Uso: patch_vendor_hwc.sh [vendor.img] [--out vendor.ksu.img]"
      exit 0 ;;
    -*) die "opção desconhecida: $a" ;;
    *) BASE=$a ;;
  esac
  shift
done
[ -f "$BASE" ] || die "vendor.img não encontrado: $BASE"
if [ -z "$OUT" ]; then
  if [ "$BASE" = "$ANDROID_DIR/vendor.img" ]; then
    OUT=$ANDROID_DIR/vendor.ksu.img
  else
    OUT=$BASE.ksu.img
  fi
fi
exec "$SCRIPT_DIR/build_vendor.sh" --base "$BASE" --out "$OUT" --hwc

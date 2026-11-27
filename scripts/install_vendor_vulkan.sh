#!/usr/bin/env bash
# Wrapper compatível: habilita Vulkan no vendor.img.
#
# Antes este script fazia o repack sozinho; agora ele delega ao pipeline único
# scripts/build_vendor.sh (um extract/repack, validação e manifesto).
#
# Uso:
#   sudo scripts/install_vendor_vulkan.sh
#   sudo scripts/install_vendor_vulkan.sh --rollback
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"

args=(--vulkan)
for a in "$@"; do
  case "$a" in
    -h|--help)
      echo "Uso: install_vendor_vulkan.sh [--rollback] [--base IMG] [--out IMG]"
      exit 0 ;;
    *) args+=("$a") ;;
  esac
done
exec "$SCRIPT_DIR/build_vendor.sh" "${args[@]}"

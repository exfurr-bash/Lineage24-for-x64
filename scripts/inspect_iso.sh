#!/usr/bin/env bash
# Inspeciona uma ISO (ou o workspace) e relata o que ela contém:
# kernel, imagens, HAL de Bluetooth, XMLs Vulkan e GApps.
#
# Uso:
#   scripts/inspect_iso.sh [ISO] [--json]
#   scripts/inspect_iso.sh --workspace
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"

ISO=$ISO_FILE
USE_WORKSPACE=0
JSON=0
for arg in "$@"; do
  case "$arg" in
    --workspace) USE_WORKSPACE=1 ;;
    --json) JSON=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ISO=$arg ;;
  esac
done

[ "$USE_WORKSPACE" = 1 ] && ISO=$WORKSPACE_DIR/iso/lineage-24.0-$BASE_RELEASE.iso
[ -f "$ISO" ] || die "ISO não encontrada: $ISO (rode scripts/fetch_sources.sh)"

TMP=$(new_tmpdir inspect)
REPORT=$TMP/report.txt
: > "$REPORT"

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }

say "ISO: $ISO"
say "tamanho: $(human_size "$(stat -c %s "$ISO")")"
say "sha256: $(sha256_of "$ISO")"

xorriso -indev "$ISO" -pvd_info 2>/dev/null | grep -E 'Volume id|Volume set id|Application id' | sed 's/^/  /' | tee -a "$REPORT" || true

say ""
say "== conteúdo de topo =="
xorriso -indev "$ISO" -ls / 2>/dev/null | sed -n '1,30p' | tee -a "$REPORT" || true

say ""
say "== imagens android =="
for p in /android-Generic_x86_64 /System /System/imgs; do
  if xorriso -osirrox on -indev "$ISO" -extract "$p" "$TMP/probe" >/dev/null 2>&1 && [ -e "$TMP/probe" ]; then
    say "  encontrado: $p"
    find "$TMP/probe" -maxdepth 3 -type f \( -name '*.img' -o -name 'kernel*' \) -printf '    %f  %s bytes\n' 2>/dev/null | sort | tee -a "$REPORT"
    [ -f "$TMP/probe/kernel" ] && say "    kernel: $(kernel_version_of "$TMP/probe/kernel")"
    break
  fi
  rm -rf "$TMP/probe"
done

# Inspeção das imagens do workspace (ou extraídas da ISO).
if [ "$USE_WORKSPACE" = 0 ]; then
  mkdir -p "$TMP/android"
  xorriso -osirrox on -indev "$ISO" -extract /android-Generic_x86_64 "$TMP/android" >/dev/null 2>&1 || true
  ANDROID=$TMP/android
else
  ANDROID=$ANDROID_DIR
fi

say ""
say "== kernel =="
if [ -f "$ANDROID/kernel" ]; then
  say "  versão: $(kernel_version_of "$ANDROID/kernel")"
  say "  tipo:   $(file -b "$ANDROID/kernel")"
else
  say "  ausente"
fi

say ""
say "== vendor.img =="
if [ -f "$ANDROID/vendor.img" ] && [ -n "${EROFS_BIN:-}" ] && [ -x "$EROFS_BIN/fsck.erofs" ]; then
  if "$EROFS_BIN/fsck.erofs" --extract="$TMP/vendor" --force "$ANDROID/vendor.img" >/dev/null 2>&1; then
    V=$TMP/vendor
    say "  build.prop frame-rate: $(grep -m1 '^ro.surface_flinger.enable_frame_rate_override=' "$V/build.prop" 2>/dev/null || echo 'ausente')"
    say "  hwc_apex:              $(grep -m1 '^ro.boot.hwc_apex=' "$V/build.prop" 2>/dev/null || echo 'ausente')"
    say "  XMLs Vulkan:           $(find "$V/etc/permissions" -maxdepth 1 -name '*vulkan*' -printf x 2>/dev/null | wc -c)"
    say "  HAL BT desktop:        $([ -x "$V/bin/hw/android.hardware.bluetooth-service.desktop" ] && echo presente || echo ausente)"
    say "  HAL BT UART default:   $([ -x "$V/bin/hw/android.hardware.bluetooth-service.default" ] && echo presente || echo ausente)"
    say "  dylibs Rust BT:        $(find "$V/lib64" -maxdepth 1 -name '*dylib.so' -printf x 2>/dev/null | wc -c)"
    say "  provider VINTF BT:     $(grep -rl 'IBluetoothHci' "$V/etc/vintf" 2>/dev/null | wc -l) arquivo(s)"
  else
    say "  falha ao extrair vendor.img"
  fi
else
  say "  não inspecionado (defina EROFS_BIN ou instale erofs-utils)"
fi

say ""
say "== system.img (GApps) =="
if [ -f "$ANDROID/system.img" ] && [ -n "${EROFS_BIN:-}" ] && [ -x "$EROFS_BIN/fsck.erofs" ]; then
  if "$EROFS_BIN/fsck.erofs" --extract="$TMP/system-probe" --force "$ANDROID/system.img" >/dev/null 2>&1; then
    found=0
    for p in product/priv-app/Phonesky system/product/priv-app/Phonesky \
             system_ext/priv-app/GoogleServicesFramework \
             system/system_ext/priv-app/GoogleServicesFramework \
             system/apex/com.google.android.gmssystem.prodvic.apex \
             apex/com.google.android.gmssystem.prodvic.apex; do
      [ -e "$TMP/system-probe/$p" ] && { say "  $p: presente"; found=1; }
    done
    [ "$found" = 0 ] && say "  GApps: ausente (system.img vanilla)"
  fi
else
  say "  não inspecionado"
fi

if [ "$JSON" = 1 ]; then
  python3 - "$ANDROID" "$ISO" <<'PY'
import json, sys, os
android, iso = sys.argv[1:3]
def sz(p): return os.path.getsize(p) if os.path.isfile(p) else None
print(json.dumps({"iso": iso, "iso_size": sz(iso), "images": {
    n: sz(os.path.join(android, n)) for n in os.listdir(android) if n.endswith((".img", "kernel"))
}}, indent=2, sort_keys=True))
PY
fi

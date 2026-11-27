#!/usr/bin/env bash
# Teste de fumaça/regressão da ISO live no QEMU, headless.
#
# Critérios (espelham a matriz de docs/KSU-prep.md):
#   - "Activated N packages" (N >= 50; >= 55 na variante GApps)
#   - sys.boot_completed=1
#   - dlkm loader successfully initialized
#   - Bluetooth: Core ver
#   - 0 SIGABRT / 0 FORTIFY: FD_SET / 0 NULL VINTF MANIFEST / 0 Kernel panic
#   - 0 ocorrências do serviço antigo vendor.bluetooth-default
#
# Uso:
#   scripts/test_qemu.sh                       # última ISO ksu em dist/
#   scripts/test_qemu.sh --iso dist/foo.iso
#   scripts/test_qemu.sh --gapps --timeout 240
#   scripts/test_qemu.sh --smoke               # só crash markers (boot curto)
#
# Requer qemu-system-x86_64. Usa KVM se /dev/kvm estiver acessível; senão TCG.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"
enable_err_trap

ISO=""
LOG=""
TIMEOUT=$QEMU_TIMEOUT
MEM=$QEMU_MEM
CPUS=$QEMU_CPUS
SMOKE=0
GAPPS=0
MIN_PKGS=50
KEEP_LOG=1
EXTRA=()

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO=${2:?}; shift ;;
    --log) LOG=${2:?}; shift ;;
    --timeout) TIMEOUT=${2:?}; shift ;;
    --mem) MEM=${2:?}; shift ;;
    --cpus) CPUS=${2:?}; shift ;;
    --min-packages) MIN_PKGS=${2:?}; shift ;;
    --gapps) GAPPS=1; MIN_PKGS=55 ;;
    --smoke) SMOKE=1 ;;
    --keep-log) KEEP_LOG=1 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; EXTRA=("$@"); break ;;
    *) die "opção desconhecida: $1" ;;
  esac
  shift
done

if [ -z "$ISO" ]; then
  ISO=$(find "$DIST_DIR" -maxdepth 1 -name 'lineage-24.0-*-live-ksu-vulkan*.iso' -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -1 | cut -d' ' -f2-)
fi
[ -n "$ISO" ] && [ -f "$ISO" ] || die "ISO não encontrada (use --iso ou rode make iso)"
require_cmd qemu-system-x86_64 timeout

if [ -z "$LOG" ]; then
  LOG=$LOG_DIR/qemu-$(basename "$ISO" .iso)-$(date +%Y%m%d-%H%M%S).log
fi
mkdir -p "$(dirname "$LOG")"

ACCEL="tcg,thread=multi"
CPU=max
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  ACCEL=kvm
  CPU=host
else
  warn "/dev/kvm inacessível; usando TCG (mais lento)"
fi
[ "$GAPPS" = 1 ] && log "modo GApps: mínimo de ${MIN_PKGS} pacotes"

# shellcheck disable=SC2054
QEMU=(qemu-system-x86_64
  -machine q35 -accel "$ACCEL" -cpu "$CPU"
  -m "$MEM" -smp "$CPUS"
  -cdrom "$ISO" -boot order=d,menu=off
  -nographic -monitor none -no-reboot
  "${EXTRA[@]}")

log "ISO: $ISO ($(human_size "$(stat -c %s "$ISO")"))"
log "QEMU: accel=$ACCEL cpu=$CPU mem=${MEM}M cpus=$CPUS timeout=${TIMEOUT}s"
log "log: $LOG"

set +e
timeout --foreground -k 15 "$TIMEOUT" "${QEMU[@]}" >"$LOG" 2>&1
rc=$?
set -e
case "$rc" in
  0) log "QEMU saiu normalmente" ;;
  124|137) log "timeout de ${TIMEOUT}s atingido (esperado num boot live)" ;;
  130|143) log "QEMU interrompido" ;;
  *) warn "QEMU saiu com rc=$rc (vou inspecionar o log mesmo assim)" ;;
esac

# ------------------------------- checks -----------------------------------
pass=0
fail=0
summary=()

ck() { # ck NOME COMANDO...
  local name=$1; shift
  if "$@"; then
    summary+=("  OK   $name")
    pass=$((pass+1))
  else
    summary+=("  FALHA $name")
    fail=$((fail+1))
  fi
}

has() { grep -Eq -- "$1" "$LOG"; }
none() { ! grep -Eq -- "$1" "$LOG"; }

pkgs=$(grep -oE 'Activated [0-9]+ packages' "$LOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || true)
summary+=("  info pacotes ativados: ${pkgs:-?}")

ck "0 Kernel panic"          none 'Kernel panic'
ck "0 SIGABRT"               none 'SIGABRT'
ck "0 FORTIFY: FD_SET"       none 'FORTIFY: FD_SET'
ck "0 NULL VINTF MANIFEST"   none 'NULL VINTF MANIFEST'

if [ "$SMOKE" = 0 ]; then
  ck "0 vendor.bluetooth-default" none 'vendor\.bluetooth-default'
  ck "dlkm loader"             has 'dlkm loader successfully initialized'
  ck "Bluetooth Core"          has 'Bluetooth: Core ver'
  ck "sys.boot_completed=1"  has 'sys\.boot_completed=1|boot_completed=1'
  if [ -n "$pkgs" ]; then
    ck "Activated >= ${MIN_PKGS} packages" test "$pkgs" -ge "$MIN_PKGS"
  else
    ck "Activated packages" false
  fi
else
  summary+=("  info --smoke: boot_completed/packages não exigidos")
fi

printf '\n== resultado QEMU ==\n%s\n' "${summary[@]}"
printf '\npass=%d fail=%d\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
  printf '\nÚltimas 40 linhas do log:\n'
  tail -40 "$LOG" | sed 's/^/  /'
  die "teste QEMU falhou ($fail critério(s)); log completo: $LOG"
fi
ok "teste QEMU verde"
if [ "$KEEP_LOG" = 0 ]; then rm -f "$LOG"; fi

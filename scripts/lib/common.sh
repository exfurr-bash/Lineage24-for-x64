#!/usr/bin/env bash
# Biblioteca comum dos scripts. Deve ser carregada com:
#   . "$(dirname "$0")/lib/common.sh"
# Define caminhos, carrega config.env, e fornece helpers de log, backup,
# validação, download e temporários.
#
# Compatível com `set -Eeuo pipefail`.

# ------------------------------- caminhos ---------------------------------
COMMON_SH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$COMMON_SH_DIR/../.." && pwd)

# config.env é carregado antes dos defaults; assignments nele substituem
# valores de ambiente com o mesmo nome. Variáveis não definidas no arquivo
# continuam vindo do ambiente e os defaults só preenchem o que falta.
if [ -f "${CONFIG_ENV:-$PROJECT_ROOT/config.env}" ]; then
  # shellcheck disable=SC1090
  . "${CONFIG_ENV:-$PROJECT_ROOT/config.env}"
fi

# Raiz/home do usuário real (scripts rodam com sudo).
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  REAL_USER=$SUDO_USER
  REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  REAL_USER=${USER:-$(id -un)}
  REAL_HOME=${HOME:-/root}
fi
export REAL_USER REAL_HOME

CACHE_DIR=${CACHE_DIR:-$PROJECT_ROOT/cache}
WORKSPACE_DIR=${WORKSPACE_DIR:-$PROJECT_ROOT/workspace}
DIST_DIR=${DIST_DIR:-$PROJECT_ROOT/dist}
BACKUP_DIR=${BACKUP_DIR:-$PROJECT_ROOT/backups}
LOG_DIR=${LOG_DIR:-$PROJECT_ROOT/logs}
TMPROOT=${TMPROOT:-$REAL_HOME/tmp/opencode}
SOURCES_LOCK=${SOURCES_LOCK:-$PROJECT_ROOT/config/sources.lock}

ANDROID_DIR=${ANDROID_DIR:-$WORKSPACE_DIR/android}
ANDROID_MOUNT=${ANDROID_MOUNT:-$REAL_HOME/mnt/android}
DIRKSU=${DIRKSU:-$WORKSPACE_DIR/android-ksu}
GBOS_PARTS_DIR=${GBOS_PARTS_DIR:-$WORKSPACE_DIR/gbos/parts}
GAPPS_SYSTEM_IMG=${GAPPS_SYSTEM_IMG:-$WORKSPACE_DIR/system-gapps.img}
SYSTEM_MOUNT_POINT=${SYSTEM_MOUNT_POINT:-/system}
VENDOR_SYSTEM_IMG=${VENDOR_SYSTEM_IMG:-$WORKSPACE_DIR/system-vendor.img}

BASE_RELEASE=${BASE_RELEASE:-20261020}
ISO_FILE=${ISO_FILE:-$WORKSPACE_DIR/iso/lineage-24.0-$BASE_RELEASE.iso}
KVER=${KVER:-7.2.0+}
KSU_TAG=${KSU_TAG:-v3.3.1}
BT_MODULES=${BT_MODULES:-bluetooth btmtk btrtl btintel btbcm btusb}
JOBS=${JOBS:-$(nproc)}
QEMU_MEM=${QEMU_MEM:-3072}
QEMU_CPUS=${QEMU_CPUS:-4}
QEMU_TIMEOUT=${QEMU_TIMEOUT:-180}

# Build do kernel (sobrescreva em config.env). Por padrão, tudo fica no
# workspace reproduzível do projeto.
KERNEL_SRC=${KERNEL_SRC:-$WORKSPACE_DIR/kernel/common}
KSU_REPO=${KSU_REPO:-$WORKSPACE_DIR/kernel/KernelSU}
PATCHES_DIR=${PATCHES_DIR:-$WORKSPACE_DIR/kernel/patches}
REFCONFIG=${REFCONFIG:-$WORKSPACE_DIR/kernel/config/kernel-current.config}
OUT_DIR=${OUT_DIR:-$WORKSPACE_DIR/kernel/out}
MODSTAGE_DIR=${MODSTAGE_DIR:-$WORKSPACE_DIR/kernel/modstaging}
KOUT=${KOUT:-$OUT_DIR/arch/x86/boot/bzImage}

# `erofs-utils` do PATH ou build local em tools/erofs/bin.
if [ -z "${EROFS_BIN:-}" ]; then
  if command -v mkfs.erofs >/dev/null 2>&1; then
    EROFS_BIN=$(dirname "$(command -v mkfs.erofs)")
  elif [ -x "$PROJECT_ROOT/tools/erofs/bin/mkfs.erofs" ]; then
    EROFS_BIN=$PROJECT_ROOT/tools/erofs/bin
  else
    EROFS_BIN=""
  fi
fi

mkdir -p "$CACHE_DIR" "$WORKSPACE_DIR" "$DIST_DIR" "$BACKUP_DIR" "$LOG_DIR"
if [ "$(id -u)" = 0 ] && [ "$REAL_USER" != root ] && [ -n "$REAL_HOME" ]; then
  REAL_GROUP=$(id -gn "$REAL_USER")
  install -d -m 700 -o "$REAL_USER" -g "$REAL_GROUP" "$TMPROOT"
else
  mkdir -p "$TMPROOT"
fi

COLOUR=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then COLOUR=1; fi
_c() { if [ "$COLOUR" = 1 ]; then printf '\033[%sm' "$1"; fi; }
_cr() { if [ "$COLOUR" = 1 ]; then printf '\033[0m'; fi; }

log()  { printf '%s>>%s %s\n' "$(_c 1; _c 34)" "$(_cr)" "$*"; }
ok()   { printf '%s✓%s %s\n' "$(_c 32)" "$(_cr)" "$*"; }
warn() { printf '%sAVISO:%s %s\n' "$(_c 33)" "$(_cr)" "$*" >&2; }
die()  { printf '%sERRO:%s %s\n' "$(_c 31)" "$(_cr)" "$*" >&2; exit 1; }

section() { printf '\n== %s ==\n' "$*"; }

# ------------------------------- validação --------------------------------
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "comando ausente: $c (rode scripts/bootstrap.sh)"
  done
}

require_root() {
  [ "$(id -u)" = 0 ] || die "rode com sudo/root (necessário para mounts/loop e preservar donos)"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_erofs() {
  [ -n "${EROFS_BIN:-}" ] || die "mkfs.erofs não encontrado; instale erofs-utils ou defina EROFS_BIN em config.env"
  [ -x "$EROFS_BIN/mkfs.erofs" ] || die "sem $EROFS_BIN/mkfs.erofs"
  [ -x "$EROFS_BIN/fsck.erofs" ] || die "sem $EROFS_BIN/fsck.erofs"
}

check_free_space() { # check_free_space DIR GB
  local dir=$1 need_gb=$2 free_gb
  free_gb=$(df -Pk "$dir" | awk 'NR==2 {print int($4/1024/1024)}')
  if [ "$free_gb" -lt "$need_gb" ]; then
    die "espaço insuficiente em $dir: ${free_gb} GiB livres, necessário ~${need_gb} GiB"
  fi
  log "espaço em $dir: ${free_gb} GiB livres (>= ${need_gb} GiB)"
}

confirm() { # confirm "pergunta" [--yes]
  local msg=$1
  if [ "${ASSUME_YES:-0}" = 1 ]; then return 0; fi
  [ -t 0 ] || die "$msg (não interativo; use --yes)"
  printf '%s [s/N] ' "$msg" >&2
  local a
  read -r a
  case "$a" in s|S|y|Y|sim|yes) return 0 ;; *) return 1 ;; esac
}

# ------------------------------- sha256 -----------------------------------
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

verify_sha256() { # verify_sha256 ARQUIVO SHA_ESPERADO [nome]
  local f=$1 want=$2 name=${3:-$(basename "$1")} got
  [ -f "$f" ] || die "arquivo ausente: $f"
  [ -n "$want" ] || die "sha256 vazio para $name (lock incompleto)"
  got=$(sha256_of "$f")
  if [ "$got" != "$want" ]; then
    die "sha256 divergente de $name: esperado $want, obtido $got (arquivo: $f)"
  fi
  ok "sha256 $name"
}

# ------------------------------- sources.lock -----------------------------
lock_get() { # lock_get KEY
  local key=$1
  [ -f "$SOURCES_LOCK" ] || die "sem $SOURCES_LOCK"
  awk -v k="$key" 'BEGIN{FS="="} $1==k {sub(/^[^=]*=/,""); print; exit}' "$SOURCES_LOCK"
}

lock_require() { # lock_require KEY...
  local k v
  for k in "$@"; do
    v=$(lock_get "$k")
    [ -n "$v" ] || die "chave $k ausente/vazia em $SOURCES_LOCK"
  done
}

lock_load() { # lock_load KEY... -> atribui variáveis de mesmo nome
  local k
  for k in "$@"; do
    printf -v "$k" '%s' "$(lock_get "$k")"
  done
}

# ------------------------------- backups ----------------------------------
_manifest_line() { printf '%s  %s\n' "$(sha256_of "$1")" "$(basename "$1")"; }

backup_once() { # backup_once ARQUIVO TAG
  local f=$1 tag=$2 dest base cur
  [ -e "$f" ] || die "backup_once: não existe $f"
  base=$(basename "$f")
  dest="$BACKUP_DIR/stock/$tag/$base"
  mkdir -p "$(dirname "$dest")"
  cur=$(sha256_of "$f")
  if [ -f "$dest" ]; then
    if [ "$(sha256_of "$dest")" = "$cur" ]; then
      log "backup já existe e confere: $dest"
      return 0
    fi
    die "backup $dest já existe com conteúdo DIFERENTE; não vou sobrescrever (preserve a cópia stock)"
  fi
  cp -a --reflink=auto "$f" "$dest"
  printf '%s  %s\n' "$cur" "$base" > "$dest.sha256"
  chmod a-w "$dest" 2>/dev/null || true
  ok "backup stock: $dest"
}

backup_run() { # backup_run ARQUIVO LABEL [ID_DA_EXECUÇÃO]
  local f=$1 label=$2 run_id=${3:-} ts destdir dest
  [ -e "$f" ] || die "backup_run: não existe $f"
  ts=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$BACKUP_DIR/runs"
  if [ -n "$run_id" ]; then
    destdir="$BACKUP_DIR/runs/$run_id-$label"
    mkdir -p "$destdir"
  else
    destdir=$(mktemp -d "$BACKUP_DIR/runs/$ts-$label.XXXXXX")
  fi
  dest="$destdir/$(basename "$f")"
  [ ! -e "$dest" ] || die "backup de execução já existe; não vou sobrescrever: $dest"
  cp -a --reflink=auto "$f" "$dest"
  _manifest_line "$dest" > "$dest.sha256"
  chmod a-w "$dest" "$dest.sha256" 2>/dev/null || true
  log "backup da execução: $dest"
}

restore_backup() { # restore_backup TAG ARQUIVO
  local tag=$1 f=$2 base dest
  base=$(basename "$f")
  dest="$BACKUP_DIR/stock/$tag/$base"
  [ -f "$dest" ] || die "sem backup $dest"
  cp -a --reflink=auto "$dest" "$f"
  chmod u+w "$f" 2>/dev/null || true
  ok "restaurado $f de $dest"
}

# ------------------------------- temporários ------------------------------
_TMPLIST_FILE=$TMPROOT/.tmpdirs.$$
: > "$_TMPLIST_FILE"
_remove_tmpdir() { # remove_tmpdir PATH criado por new_tmpdir
  local d=$1
  case "$d" in
    "$TMPROOT"/*) ;;
    *) warn "recusando remover temporário fora de TMPROOT: $d"; return 0 ;;
  esac
  [ -d "$d" ] || return 0
  # Alguns temporários são pontos de montagem EROFS. Desmonte antes de
  # alterar permissões ou apagar; um mount ro produz EROFS em rm/chmod.
  if mountpoint -q "$d"; then
    umount "$d" || { warn "não consegui desmontar temporário: $d"; return 0; }
  fi
  # xorriso preserva diretórios somente leitura da ISO; libere a escrita
  # para o dono antes de apagar o diretório temporário.
  chmod -R u+w -- "$d" 2>/dev/null || true
  rm -rf -- "$d" || warn "não consegui remover temporário: $d"
}
_cleanup_tmpdirs() {
  local d
  if [ -f "$_TMPLIST_FILE" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && _remove_tmpdir "$d"
    done < "$_TMPLIST_FILE"
    rm -f -- "$_TMPLIST_FILE"
  fi
  return 0
}
trap _cleanup_tmpdirs EXIT

new_tmpdir() { # new_tmpdir [prefixo]
  local d
  d=$(mktemp -d "$TMPROOT/${1:-work}.XXXXXX") || die "mktemp falhou em $TMPROOT"
  # A chamada costuma ser feita em command substitution (subshell); por isso
  # registramos o caminho num arquivo, não num array.
  printf '%s\n' "$d" >> "$_TMPLIST_FILE"
  printf '%s\n' "$d"
}

# ------------------------------- misc ------------------------------------
human_size() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }

is_mountpoint() { mountpoint -q "$1"; }

safe_unmount() { # safe_unmount DIR
  local d=$1
  if is_mountpoint "$d"; then umount "$d" || warn "falha ao desmontar $d"; fi
  [ -d "$d" ] && rmdir "$d" 2>/dev/null || true
}

file_is_bzimage() { [ -f "$1" ] && file -b "$1" | grep -qi 'Linux kernel x86 boot executable'; }

kernel_version_of() { # kernel_version_of BZIMAGE
  file -b "$1" | sed -n 's/.*version \([^ ]*\).*/\1/p'
}

# Trap de erro com linha (scripts podem sobrescrever).
enable_err_trap() {
  set -E
  # shellcheck disable=SC2154
  trap 'rc=$?; warn "falhou na linha $LINENO (rc=$rc): $BASH_COMMAND"' ERR
}

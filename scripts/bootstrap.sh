#!/usr/bin/env bash
# Verifica (e opcionalmente instala) as dependências do projeto.
#
# Uso:
#   scripts/bootstrap.sh                 # só verifica
#   scripts/bootstrap.sh --install       # instala o grupo "runtime" + "build"
#   scripts/bootstrap.sh --install --with-test --with-release
#   scripts/bootstrap.sh --with-rust     # instala toolchain Rust via rustup
#
# Grupos:
#   runtime : curl git python3 lz4 xorriso erofs-utils coreutils
#   build   : clang lld bc flex bison libelf-dev libssl-dev gcc make
#   test    : qemu-system-x86 shellcheck jq
#   release : gh
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"

INSTALL=0
WITH_TEST=0
WITH_RELEASE=0
WITH_RUST=0

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --with-test) WITH_TEST=1 ;;
    --with-release) WITH_RELEASE=1 ;;
    --with-rust) WITH_RUST=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "opção desconhecida: $arg (use --help)" ;;
  esac
done

RUNTIME=(curl git python3 lz4 xorriso file flock numfmt)
BUILD=(clang lld bc flex bison make gcc)
TEST=(qemu-system-x86_64 shellcheck jq)
RELEASE=(gh)

missing=()
check_group() {
  local c
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then missing+=("$c"); fi
  done
}

section "verificando dependências"
check_group "${RUNTIME[@]}"
check_group "${BUILD[@]}"
[ "$WITH_TEST" = 1 ] && check_group "${TEST[@]}"
[ "$WITH_RELEASE" = 1 ] && check_group "${RELEASE[@]}"

# erofs-utils: precisa de extract com xattrs e mount-point no mkfs.
if ! command -v mkfs.erofs >/dev/null 2>&1; then
  missing+=("erofs-utils")
else
  if ! mkfs.erofs --help 2>&1 | grep -q -- '--mount-point'; then
    warn "mkfs.erofs sem --mount-point (versão antiga); defina EROFS_BIN com build >= 1.7"
  fi
  if ! fsck.erofs --help 2>&1 | grep -q -- '--extract'; then
    warn "fsck.erofs sem --extract (versão antiga); defina EROFS_BIN com build >= 1.7"
  fi
fi

# Rust: o kernel 7.2 exige a toolchain pinada.
RUST_NEEDED=${RUST_TOOLCHAIN:-1.93.1}
if [ "$WITH_RUST" = 1 ]; then
  command -v rustup >/dev/null 2>&1 || missing+=("rustup")
else
  if ! command -v rustc >/dev/null 2>&1; then
    warn "rustc ausente; o build do kernel exige Rust $RUST_NEEDED (use --with-rust)"
  else
    rustc --version | sed 's/^/   /'
  fi
fi

if [ "${#missing[@]}" -gt 0 ]; then
  printf '\n%s\n' "Pacotes/comandos ausentes:"
  printf '   %s\n' "${missing[*]}"
else
  ok "todas as dependências verificadas estão presentes"
fi

if [ "$INSTALL" = 0 ]; then
  cat <<EOF

Para instalar (Debian/Ubuntu):
  sudo scripts/bootstrap.sh --install$([ "$WITH_TEST" = 1 ] && echo ' --with-test')$([ "$WITH_RELEASE" = 1 ] && echo ' --with-release')
EOF
  exit 0
fi

[ "$INSTALL" = 0 ] || [ "$(id -u)" = 0 ] || die "--install exige root/sudo"

if command -v pacman >/dev/null 2>&1; then
  PM=pacman
elif command -v apt-get >/dev/null 2>&1; then
  PM=apt
elif command -v dnf >/dev/null 2>&1; then
  PM=dnf
else
  die "gerenciador de pacotes não suportado (pacman/apt/dnf); instale manualmente: ${missing[*]}"
fi

section "instalando dependências ($PM)"
case "$PM" in
  pacman)
    pkgs=(base-devel curl git python lz4 xorriso file erofs-utils clang lld bc flex bison libelf openssl pkgconf)
    [ "$WITH_TEST" = 1 ] && pkgs+=(qemu-system-x86 shellcheck jq)
    [ "$WITH_RELEASE" = 1 ] && pkgs+=(github-cli)
    pacman -S --needed --noconfirm "${pkgs[@]}"
    ;;
  apt)
    pkgs=(curl git python3 lz4 xorriso file util-linux coreutils clang lld bc flex bison make gcc libelf-dev libssl-dev pkg-config ca-certificates erofs-utils)
    [ "$WITH_TEST" = 1 ] && pkgs+=(qemu-system-x86 shellcheck jq)
    [ "$WITH_RELEASE" = 1 ] && pkgs+=(gh)
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
    ;;
  dnf)
    pkgs=(curl git python3 lz4 xorriso file util-linux coreutils clang lld bc flex bison make gcc elfutils-libelf-devel openssl-devel pkgconf-pkg-config ca-certificates erofs-utils)
    [ "$WITH_TEST" = 1 ] && pkgs+=(qemu-system-x86 shellcheck jq)
    [ "$WITH_RELEASE" = 1 ] && pkgs+=(gh)
    dnf install -y "${pkgs[@]}"
    ;;
esac

if [ "$WITH_RUST" = 1 ]; then
  if ! command -v rustup >/dev/null 2>&1; then
    section "instalando rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
  fi
  # rustup foi instalado no HOME do root; usa explicitamente o toolchain pedido.
  RUSTUP_HOME=${RUSTUP_HOME:-/root/.rustup}
  if [ "$REAL_USER" != root ]; then
    RUSTUP_HOME="/home/$REAL_USER/.rustup"
  fi
  "$RUSTUP_HOME/toolchains" >/dev/null 2>&1 || true
  if [ -x "$HOME/.cargo/bin/rustup" ]; then
    "$HOME/.cargo/bin/rustup" toolchain install "$RUST_NEEDED"
  else
    warn "rustup instalado mas não encontrado; rode 'rustup toolchain install $RUST_NEEDED' como $REAL_USER"
  fi
fi

ok "bootstrap concluído"

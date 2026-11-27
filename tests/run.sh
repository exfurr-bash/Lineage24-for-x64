#!/usr/bin/env bash
# Testes unitários das bibliotecas Python e dos helpers shell.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
mkdir -p "$HOME/tmp/opencode"
export TMPDIR="$HOME/tmp/opencode"

fail=0

section() { printf '\n== %s ==\n' "$*"; }

section "sintaxe bash"
while IFS= read -r f; do
  if bash -n "$f"; then :; else fail=1; fi
done < <(find scripts tests -name '*.sh' -type f | sort)

section "sintaxe Python"
if python3 -m py_compile scripts/lib/*.py tests/*.py; then :; else fail=1; fi

section "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # -x segue os `source`; o código é testado como shell, não como framework.
  if ! shellcheck -x scripts/*.sh scripts/lib/*.sh tests/*.sh; then fail=1; fi
else
  echo "AVISO: shellcheck ausente; pulando (scripts/bootstrap.sh --install --with-test)"
fi

section "unittest"
if ! python3 -m unittest discover -s tests -p 'test_*.py' -v; then fail=1; fi

section "common.sh"
if ! bash tests/test_common.sh; then fail=1; fi

if [ "$fail" != 0 ]; then
  echo "TESTES FALHARAM" >&2
  exit 1
fi
echo
echo "TESTES OK"

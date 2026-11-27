#!/usr/bin/env bash
# Testa helpers de scripts/lib/common.sh sem tocar no workspace real.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMPROOT="$HOME/tmp/opencode"
mkdir -p "$TEST_TMPROOT"
TMP=$(mktemp -d "$TEST_TMPROOT/test-common.XXXXXX")
cleanup() { chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"; }
export CONFIG_ENV=$TMP/empty.env
: > "$CONFIG_ENV"
export CACHE_DIR=$TMP/cache
export WORKSPACE_DIR=$TMP/workspace
export DIST_DIR=$TMP/dist
export BACKUP_DIR=$TMP/backups
export LOG_DIR=$TMP/logs
export TMPROOT=$TMP/tmp
mkdir -p "$TMPROOT"
mkdir -p "$TMP/backups/runs" "$TMP/backups/stock"
export SOURCES_LOCK=$TMP/sources.lock
cat > "$SOURCES_LOCK" <<'EOF'
# fixture
BASE_ASSET_AA_SHA256=abc123
URL=https://example.invalid/a?x=1
EMPTY=
EOF

# shellcheck source=../scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"
# Substitui o trap da biblioteca (que limpa só os new_tmpdir) por um que
# remove também a raiz temporária do teste.
trap cleanup EXIT

fails=0
ck() { # ck nome comando...
  local name=$1; shift
  if "$@"; then printf '  OK   %s\n' "$name"; else printf '  FALHA %s\n' "$name" >&2; fails=$((fails+1)); fi
}

printf '== common.sh ==\n'
ck "lock_get simples" test "$(lock_get BASE_ASSET_AA_SHA256)" = abc123
ck "lock_get preserva '='" test "$(lock_get URL)" = "https://example.invalid/a?x=1"
ck "lock_get vazio" test -z "$(lock_get EMPTY)"

printf 'hello\n' > "$TMP/f1"
sum=$(sha256_of "$TMP/f1")
ck "sha256_of" test "${#sum}" = 64
ck "verify_sha256 ok" verify_sha256 "$TMP/f1" "$sum"
if ( verify_sha256 "$TMP/f1" 0000 >/dev/null 2>&1 ); then
  printf '  FALHA verify_sha256 aceitou hash errado\n' >&2; fails=$((fails+1))
else
  printf '  OK   verify_sha256 rejeita hash errado\n'
fi

printf 'stock\n' > "$TMP/stock.img"
backup_once "$TMP/stock.img" vendor
ck "backup_once criado" test -f "$TMP/backups/stock/vendor/stock.img"
ck "backup_once sha" test -f "$TMP/backups/stock/vendor/stock.img.sha256"
ck "backup_once idempotente" backup_once "$TMP/stock.img" vendor
printf 'run\n' > "$TMP/run.img"
backup_run "$TMP/run.img" install-ksu
ck "backup_run" test "$(find "$TMP/backups/runs" -name run.img | wc -l)" -ge 1
backup_run "$TMP/run.img" install-ksu grouped-123
backup_run "$TMP/f1" install-ksu grouped-123
ck "backup_run agrupa arquivo principal" test -f "$TMP/backups/runs/grouped-123-install-ksu/run.img"
ck "backup_run agrupa arquivo adicional" test -f "$TMP/backups/runs/grouped-123-install-ksu/f1"

printf 'changed\n' > "$TMP/stock.img"
restore_backup vendor "$TMP/stock.img"
ck "restore_backup" test "$(cat "$TMP/stock.img")" = stock

d=$(new_tmpdir teste)
ck "new_tmpdir dentro de TMPROOT" test "${d#"$TMPROOT"/}" != "$d"
ck "human_size" test -n "$(human_size 1024)"
ck "have_cmd sh" have_cmd sh
if ( require_cmd comando-que-nao-existe >/dev/null 2>&1 ); then
  printf '  FALHA require_cmd aceitou comando inexistente\n' >&2; fails=$((fails+1))
else
  printf '  OK   require_cmd rejeita ausente\n'
fi

if [ "$fails" != 0 ]; then
  printf 'common.sh: %d falha(s)\n' "$fails" >&2
  exit 1
fi
printf 'common.sh OK\n'

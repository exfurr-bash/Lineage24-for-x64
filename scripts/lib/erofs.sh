#!/usr/bin/env bash
# Helpers de EROFS (extração, repack, mtime e verificação por loop mount).
# Requer scripts/lib/common.sh carregado antes e root para mounts/xattrs.

erofs_extract() { # erofs_extract IMG OUTDIR
  local img=$1 out=$2
  require_erofs
  [ -f "$img" ] || die "erofs_extract: sem $img"
  log "extraindo $(basename "$img")"
  rm -rf "$out"
  mkdir -p "$out"
  if "$EROFS_BIN/fsck.erofs" --extract="$out" --force --preserve --xattrs "$img" >/dev/null 2>&1; then
    :
  else
    # Versões antigas de fsck.erofs não suportam --xattrs. O loop mount
    # preserva SELinux/capabilities de verdade, então é o fallback seguro.
    warn "fsck.erofs não extraiu com xattrs; usando loop mount + cp -a"
    rm -rf "$out"
    mkdir -p "$out"
    mount -o ro,loop "$img" "$out" || die "mount loop falhou: $img"
    local tmp
    tmp=$(new_tmpdir erofs-copy)
    cp -a --reflink=auto "$out/." "$tmp/" || { umount "$out"; die "cp -a falhou em $img"; }
    umount "$out"
    rm -rf "$out"
    mkdir -p "$out"
    cp -a --reflink=auto "$tmp/." "$out/" || die "cópia final falhou em $img"
  fi
  ok "extraído: $(basename "$img") ($(find "$out" -type f | wc -l) arquivos)"
}

erofs_mtime() { # erofs_mtime IMG -> epoch ou vazio
  local img=$1 ts
  require_erofs
  ts=$("$EROFS_BIN/dump.erofs" -s "$img" 2>/dev/null \
        | awk '/Filesystem created/ {sub(/^Filesystem created: /,""); print; exit}')
  [ -n "$ts" ] || return 0
  date -u -d "$ts" +%s 2>/dev/null || true
}

erofs_repack() { # erofs_repack OUT SRCDIR MOUNTPOINT [MTIME_EPOCH]
  local out=$1 src=$2 mp=$3 t=${4:-}
  require_erofs
  [ -d "$src" ] || die "erofs_repack: sem $src"
  mkdir -p "$(dirname "$out")"
  if [ -n "$t" ] && [ "$t" -gt 0 ] 2>/dev/null; then
    "$EROFS_BIN/mkfs.erofs" -zlz4 --mount-point="$mp" --preserve-mtime -T "$t" "$out" "$src" \
      || die "mkfs.erofs falhou para $out"
  else
    "$EROFS_BIN/mkfs.erofs" -zlz4 --mount-point="$mp" --preserve-mtime "$out" "$src" \
      || die "mkfs.erofs falhou para $out"
  fi
  ok "repack: $(basename "$out") ($(human_size "$(stat -c %s "$out")"))"
}

loop_mount_ro() { # loop_mount_ro IMG MNT
  local img=$1 mnt=$2
  mkdir -p "$mnt"
  mount -o ro,loop "$img" "$mnt" || die "mount loop falhou: $img"
}

loop_umount() { safe_unmount "$1"; }

file_list() { # file_list ROOT OUTFILE
  ( cd "$1" && find . \( -type f -o -type l \) -printf '%P\n' | sort ) > "$2"
}

count_ko() { find "$1" -name '*.ko' 2>/dev/null | wc -l; }

# Compara a lista de arquivos antes/depois e guarda o delta em arquivo.
file_list_delta() { # file_list_delta ANTES DEPOIS SAIDA
  comm -3 "$1" "$2" > "$3" || true
  wc -l < "$3"
}

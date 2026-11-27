#!/usr/bin/env bash
# Baixa e verifica as fontes do projeto, montando o workspace local.
#
# Perfis:
#   vanilla       ISO base + imagens do android-Generic_x86_64 (KSU + Vulkan)
#   gapps         vanilla + partições do Google via gbOS86 (GApps + HAL BT desktop)
#   github-gapps  vanilla + system.img com GApps do upstream 20260914 (100% GitHub,
#                 porém sem HAL BT desktop e em base mais antiga)
#   all           gapps + github-gapps
#
# Uso:
#   scripts/fetch_sources.sh --profile gapps
#   scripts/fetch_sources.sh --profile vanilla --release 20261122
#   scripts/fetch_sources.sh --profile gapps --dry-run
#   scripts/fetch_sources.sh --refresh-pins      # audita/imprime hashes, não altera o lock
#
# Temporários vão para $HOME/tmp/opencode.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib/common.sh"
enable_err_trap

PROFILE=gapps
RELEASE=$BASE_RELEASE
DRY=0
REFRESH_PINS=0
SKIP_ISO=0
SKIP_GAPPS=0

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE=${2:?}; shift ;;
    --profile=*) PROFILE=${1#*=} ;;
    --release) RELEASE=${2:?}; shift ;;
    --release=*) RELEASE=${1#*=} ;;
    --dry-run) DRY=1 ;;
    --refresh-pins) REFRESH_PINS=1 ;;
    --skip-iso) SKIP_ISO=1 ;;
    --skip-gapps) SKIP_GAPPS=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "opção desconhecida: $1" ;;
  esac
  shift
done

case "$PROFILE" in vanilla|gapps|github-gapps|all) ;; *) die "perfil inválido: $PROFILE" ;; esac

lock_require BASE_RELEASE BASE_RELEASE_TAG BASE_RELEASE_BASE_URL \
  BASE_ASSET_AA BASE_ASSET_AA_SHA256 BASE_ASSET_AB BASE_ASSET_AB_SHA256
lock_load BASE_RELEASE_TAG BASE_RELEASE_BASE_URL BASE_ASSET_AA BASE_ASSET_AA_SHA256 \
  BASE_ASSET_AB BASE_ASSET_AB_SHA256 BASE_ISO_SHA256 GBOS_PARTS
GBOS_PARTS=${GBOS_PARTS:-vendor_a product_a system_ext_a}
read -r -a GBOS_PART_LIST <<< "$GBOS_PARTS"

verify_project_assets() {
  local file key want
  while IFS='|' read -r file key; do
    want=$(lock_get "$key")
    verify_sha256 "$PROJECT_ROOT/vendor-vulkan-xmls/$file" "$want" "$file"
  done <<'EOF'
android.hardware.vulkan.compute-0.prebuilt.xml|VULKAN_XML_COMPUTE_SHA256
android.hardware.vulkan.level-1.prebuilt.xml|VULKAN_XML_LEVEL_SHA256
android.hardware.vulkan.version-1_3.prebuilt.xml|VULKAN_XML_VERSION_SHA256
android.software.opengles.deqp.level-latest.prebuilt.xml|VULKAN_XML_GLES_DEQP_SHA256
android.software.vulkan.deqp.level-latest.prebuilt.xml|VULKAN_XML_VK_DEQP_SHA256
EOF
}
verify_project_assets

if [ "$RELEASE" = "$BASE_RELEASE" ]; then
  REL_TAG=$BASE_RELEASE_TAG
  REL_URL=$BASE_RELEASE_BASE_URL
  ASSET_AA=$BASE_ASSET_AA
  ASSET_AB=$BASE_ASSET_AB
  SHA_AA=$BASE_ASSET_AA_SHA256
  SHA_AB=$BASE_ASSET_AB_SHA256
  SHA_ISO=$(lock_get BASE_ISO_SHA256)
elif [ "$RELEASE" = "$(lock_get RELEASE_NEXT)" ]; then
  REL_TAG=$(lock_get RELEASE_NEXT_TAG)
  REL_URL=$(lock_get RELEASE_NEXT_BASE_URL)
  ASSET_AA=lineage-24.0_aa
  ASSET_AB=lineage-24.0_ab
  SHA_AA=$(lock_get RELEASE_NEXT_AA_SHA256)
  SHA_AB=$(lock_get RELEASE_NEXT_AB_SHA256)
  SHA_ISO=""
  warn "release $RELEASE é a base nova (kernel $(lock_get RELEASE_NEXT_KERNEL_SERIES)); exige revalidação completa (docs/MIGRATION-20261122.md)"
else
  die "release desconhecido: $RELEASE (conhecidos: $BASE_RELEASE, $(lock_get RELEASE_NEXT))"
fi

ISO_DIR=$CACHE_DIR/iso/$RELEASE
ISO_FILE=$WORKSPACE_DIR/iso/lineage-24.0-$RELEASE.iso
mkdir -p "$ISO_DIR" "$WORKSPACE_DIR/iso" "$GBOS_PARTS_DIR"

# ------------------------------- helpers ----------------------------------
download() { # download URL DEST SHA256 [TAMANHO]
  local url=$1 dest=$2 want=$3 size=${4:-0}
  [ -n "$want" ] || die "sem sha256 pinado para $(basename "$dest")"
  if [ -f "$dest" ] && [ "$(sha256_of "$dest")" = "$want" ]; then
    ok "já baixado e verificado: $(basename "$dest")"
    return 0
  fi
  if [ "$DRY" = 1 ]; then
    log "[dry-run] baixaria $url -> $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  log "baixando $(basename "$dest")"
  # curl -C - retoma; se o servidor não suportar range, recomeça do zero.
  if ! curl -fL --retry 5 --retry-delay 3 -C - -o "$dest.part" "$url"; then
    rm -f "$dest.part"
    curl -fL --retry 5 --retry-delay 3 -o "$dest.part" "$url" || die "download falhou: $url"
  fi
  if [ "$size" -gt 0 ] 2>/dev/null; then
    local got; got=$(stat -c %s "$dest.part")
    [ "$got" = "$size" ] || warn "tamanho de $(basename "$dest") difere (esperado $size, obtido $got)"
  fi
  verify_sha256 "$dest.part" "$want" "$(basename "$dest")"
  mv -f "$dest.part" "$dest"
}

fetch_iso_parts() {
  local aa=$ISO_DIR/$ASSET_AA ab=$ISO_DIR/$ASSET_AB
  if [ "$SKIP_ISO" = 1 ] && [ -f "$ISO_FILE" ]; then
    ok "ISO já presente: $ISO_FILE"; return 0
  fi
  if [ "$DRY" = 1 ]; then
    log "[dry-run] baixaria $REL_URL/$ASSET_AA e $ASSET_AB"
    return 0
  fi
  download "$REL_URL/$ASSET_AA" "$aa" "$SHA_AA"
  download "$REL_URL/$ASSET_AB" "$ab" "$SHA_AB"
  if [ ! -f "$ISO_FILE" ] || ! cmp -s "$ISO_FILE" <(cat "$aa" "$ab"); then
    log "juntando partes em $(basename "$ISO_FILE")"
    cat "$aa" "$ab" > "$ISO_FILE.part"
    mv -f "$ISO_FILE.part" "$ISO_FILE"
  fi
  if [ -n "$SHA_ISO" ]; then
    verify_sha256 "$ISO_FILE" "$SHA_ISO" "$(basename "$ISO_FILE")"
  else
    warn "BASE_ISO_SHA256 vazio; ISO foi reunida das partes verificadas (rode --refresh-pins para registrar o hash completo)"
  fi
  ok "ISO: $ISO_FILE ($(human_size "$(stat -c %s "$ISO_FILE")"))"
}

extract_android_dir() {
  [ "$DRY" = 1 ] && { log "[dry-run] extrairia android-Generic_x86_64 da ISO"; return 0; }
  command -v xorriso >/dev/null 2>&1 || die "xorriso ausente"
  local tmp; tmp=$(new_tmpdir iso-extract)
  local found=""
  for cand in android-Generic_x86_64 System System/imgs android; do
    if xorriso -osirrox on -indev "$ISO_FILE" -extract "/$cand" "$tmp/x" >/dev/null 2>&1 && [ -e "$tmp/x" ]; then
      found=$tmp/x; break
    fi
    _remove_tmpdir "$tmp/x"
  done
  [ -n "$found" ] || die "não achei as imagens dentro da ISO (procurei android-Generic_x86_64/System); rode scripts/inspect_iso.sh"
  log "imagens encontradas em /${found#"$tmp"/}"

  mkdir -p "$ANDROID_DIR"
  # Mapeia nomes esperados (tolera diretórios aninhados).
  declare -A want=(
    [kernel]="kernel"
    [ramdisk-all-combined.img]="ramdisk-all-combined.img"
    [system.img]="system.img"
    [vendor.img]="vendor.img"
    [vendor_dlkm.img]="vendor_dlkm.img"
    [system_dlkm.img]="system_dlkm.img"
    [firmware.img]="firmware.img"
  )
  local name src
  for name in "${!want[@]}"; do
    src=$(find "$found" -maxdepth 3 -name "$name" -type f -print -quit)
    if [ -z "$src" ] && [ "$name" = kernel ]; then
      src=$(find "$found" -maxdepth 3 \( -name 'kernel.ksu' -o -name 'bzImage' \) -type f -print -quit)
    fi
    if [ -n "$src" ]; then
      if [ -e "$ANDROID_DIR/$name" ] && [ "$(sha256_of "$src")" = "$(sha256_of "$ANDROID_DIR/$name")" ]; then
        ok "já presente: $name"
      else
        cp -a --reflink=auto "$src" "$ANDROID_DIR/$name"
        ok "extraído: $name ($(human_size "$(stat -c %s "$ANDROID_DIR/$name")"))"
      fi
    elif [ "$name" = firmware.img ] || [ "$name" = system_dlkm.img ]; then
      warn "opcional ausente na ISO: $name"
    else
      die "obrigatório ausente na ISO: $name"
    fi
  done
  file_is_bzimage "$ANDROID_DIR/kernel" || die "$ANDROID_DIR/kernel não parece um bzImage"
}

fetch_gbos_tools() {
  lock_require GBOS_REPO_URL GBOS_COMMIT GBOS_RECOVERY_URL GBOS_RECOVERY_SHA256
  lock_load GBOS_REPO_URL GBOS_COMMIT GBOS_RECOVERY_URL GBOS_RECOVERY_SHA256
  local repo=$CACHE_DIR/gbos86
  if [ "$DRY" = 1 ]; then
    log "[dry-run] usaria $GBOS_REPO_URL @ $GBOS_COMMIT"; return 0
  fi
  if [ ! -d "$repo/.git" ]; then
    log "clonando gbOS86 (pin $GBOS_COMMIT)"
    git clone --filter=blob:none --no-checkout "$GBOS_REPO_URL" "$repo"
  fi
  if ! git -C "$repo" cat-file -e "$GBOS_COMMIT^{commit}" 2>/dev/null; then
    git -C "$repo" fetch --depth=1 origin "$GBOS_COMMIT"
  fi
  git -C "$repo" checkout -q --detach "$GBOS_COMMIT"
  [ -f "$repo/tools/fetch_google_parts.py" ] || die "gbOS86 pinado sem tools/fetch_google_parts.py"
  [ -f "$repo/lapis/BUILD" ] || die "gbOS86 pinado sem lapis/BUILD"
  grep -q "URL=$GBOS_RECOVERY_URL" "$repo/lapis/BUILD" \
    || die "URL da recovery mudou no gbOS86 pinado; revise config/sources.lock"
  if [ -f "$repo/lapis/recovery.zip.sha256" ]; then
    local sha_in; sha_in=$(awk '{print $1}' "$repo/lapis/recovery.zip.sha256")
    [ "$sha_in" = "$GBOS_RECOVERY_SHA256" ] \
      || die "sha da recovery no gbOS86 pinado difere do lock (repo: $sha_in)"
  fi
  ok "gbOS86 @ $GBOS_COMMIT"
}

fetch_gbos_parts() {
  [ "$SKIP_GAPPS" = 1 ] && { warn "GApps/BT pulados (--skip-gapps)"; return 0; }
  fetch_gbos_tools
  local zip=$CACHE_DIR/google/recovery.zip
  download "$GBOS_RECOVERY_URL" "$zip" "$GBOS_RECOVERY_SHA256"
  [ "$DRY" = 1 ] && return 0
  local repo=$CACHE_DIR/gbos86
  local missing=0 p
  for p in "${GBOS_PART_LIST[@]}"; do
    [ -s "$GBOS_PARTS_DIR/$p.img" ] || missing=1
  done
  if [ "$missing" = 1 ]; then
    log "extraindo partições do Google: $GBOS_PARTS"
    ( cd "$repo" && python3 tools/fetch_google_parts.py "$zip" "$GBOS_PARTS_DIR" "${GBOS_PART_LIST[@]}" )
  else
    ok "partições gbOS já extraídas em $GBOS_PARTS_DIR"
  fi
  for p in "${GBOS_PART_LIST[@]}"; do
    [ -s "$GBOS_PARTS_DIR/$p.img" ] || die "partição ausente após extração: $p.img"
    ok "gbOS: $p.img ($(human_size "$(stat -c %s "$GBOS_PARTS_DIR/$p.img")"))"
  done
}

fetch_github_gapps() {
  lock_require UPSTREAM_GAPPS_TAG UPSTREAM_GAPPS_BASE_URL \
    UPSTREAM_GAPPS_ASSET_AA UPSTREAM_GAPPS_ASSET_AA_SHA256 \
    UPSTREAM_GAPPS_ASSET_AB UPSTREAM_GAPPS_ASSET_AB_SHA256 UPSTREAM_GAPPS_IMG_SHA256
  lock_load UPSTREAM_GAPPS_TAG UPSTREAM_GAPPS_BASE_URL \
    UPSTREAM_GAPPS_ASSET_AA UPSTREAM_GAPPS_ASSET_AA_SHA256 \
    UPSTREAM_GAPPS_ASSET_AB UPSTREAM_GAPPS_ASSET_AB_SHA256 UPSTREAM_GAPPS_IMG_SHA256
  local dir=$CACHE_DIR/gapps-20260914
  local aa=$dir/$UPSTREAM_GAPPS_ASSET_AA ab=$dir/$UPSTREAM_GAPPS_ASSET_AB
  mkdir -p "$dir"
  download "$UPSTREAM_GAPPS_BASE_URL/$UPSTREAM_GAPPS_ASSET_AA" "$aa" "$UPSTREAM_GAPPS_ASSET_AA_SHA256"
  download "$UPSTREAM_GAPPS_BASE_URL/$UPSTREAM_GAPPS_ASSET_AB" "$ab" "$UPSTREAM_GAPPS_ASSET_AB_SHA256"
  [ "$DRY" = 1 ] && return 0
  cat "$aa" "$ab" > "$GAPPS_SYSTEM_IMG.part"
  verify_sha256 "$GAPPS_SYSTEM_IMG.part" "$UPSTREAM_GAPPS_IMG_SHA256" "system-with-gapps.img"
  mv -f "$GAPPS_SYSTEM_IMG.part" "$GAPPS_SYSTEM_IMG"
  ok "system.img GApps: $GAPPS_SYSTEM_IMG"
}

write_manifest() {
  [ "$DRY" = 1 ] && return 0
  python3 - "$WORKSPACE_DIR/SOURCES.json" "$RELEASE" "$PROFILE" "$ISO_FILE" "$ANDROID_DIR" <<'PY'
import hashlib, json, os, sys, time
out, release, profile, iso, android = sys.argv[1:6]
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(8 << 20), b""):
            h.update(b)
    return h.hexdigest()
def info(p):
    if not os.path.isfile(p):
        return None
    return {"path": p, "size": os.path.getsize(p), "sha256": sha(p)}
data = {
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "release": release,
    "profile": profile,
    "iso": info(iso),
    "android": {n: info(os.path.join(android, n)) for n in
                ("kernel", "ramdisk-all-combined.img", "system.img", "vendor.img",
                 "vendor_dlkm.img", "system_dlkm.img", "firmware.img")},
}
json.dump(data, open(out, "w"), indent=2, sort_keys=True)
print("manifesto:", out)
PY
}

refresh_pins() {
  section "refresh-pins (auditoria; nada é alterado)"
  if [ -f "$ISO_FILE" ]; then
    printf 'BASE_ISO_SHA256=%s\n' "$(sha256_of "$ISO_FILE")"
  else
    warn "ISO ainda não baixada; rode sem --refresh-pins primeiro"
  fi
  if [ -f "$GAPPS_SYSTEM_IMG" ]; then
    printf 'UPSTREAM_GAPPS_IMG_SHA256=%s\n' "$(sha256_of "$GAPPS_SYSTEM_IMG")"
  fi
  if [ -d "$CACHE_DIR/gbos86/.git" ]; then
    printf 'GBOS_COMMIT=%s\n' "$(git -C "$CACHE_DIR/gbos86" rev-parse HEAD)"
  fi
  exit 0
}

# ------------------------------- execução ---------------------------------
if [ "$REFRESH_PINS" = 1 ]; then refresh_pins; fi

exec 9>"$CACHE_DIR/.fetch.lock"
flock -n 9 || die "outro fetch_sources.sh está rodando (lock: $CACHE_DIR/.fetch.lock)"

case "$PROFILE" in
  vanilla) need_gb=8 ;;
  gapps) need_gb=30 ;;
  github-gapps) need_gb=12 ;;
  all) need_gb=32 ;;
esac
check_free_space "$CACHE_DIR" "$need_gb"

section "release $RELEASE ($REL_TAG)"
fetch_iso_parts
extract_android_dir

case "$PROFILE" in
  vanilla) ;;
  gapps) fetch_gbos_parts ;;
  github-gapps) fetch_github_gapps ;;
  all) fetch_gbos_parts; fetch_github_gapps ;;
esac

write_manifest
section "concluído"
cat <<EOF
Workspace: $WORKSPACE_DIR
  ISO:     $ISO_FILE
  Android: $ANDROID_DIR
  gbOS:    $GBOS_PARTS_DIR (perfil gapps)
Próximo passo: scripts/inspect_iso.sh && make kernel
EOF

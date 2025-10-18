# meta.sh
# Meta manifest handling: read/write, signature verification, and locking.
# 2.2 adds audit trail #run lines appended to meta on write.

META_HEADER="#meta"; META_VER="v1"

read_meta() {
  local meta="$1"
  declare -gA meta_hash_by_path meta_mtime meta_size meta_inode_dev meta_path_by_inode
  meta_hash_by_path=(); meta_mtime=(); meta_size=(); meta_inode_dev=(); meta_path_by_inode=()
  [ -f "$meta" ] || return 0
  while IFS=$'\t' read -r path inode dev mtime size hash; do
    [ -z "$path" ] && continue
    case "$path" in \#meta|\#sig|\#run) continue ;; # skip headers/signature and audit lines
    esac
    meta_hash_by_path["$path"]="$hash"
    meta_mtime["$path"]="$mtime"
    meta_size["$path"]="$size"
    meta_inode_dev["$path"]="${inode}:${dev}"
    meta_path_by_inode["${inode}:${dev}"]="$path"
  done < "$meta"
}

verify_meta_sig() {
  local meta="$1" tmp stored expected
  [ -f "$meta" ] || return 0
  [ "$META_SIG_ALGO" = "none" ] && return 0
  stored=$(awk -F'\t' '/^#sig\t/ {print $2; exit}' "$meta" 2>/dev/null)
  [ -z "$stored" ] && return 0
  tmp=$(mktemp) || return 2
  # exclude signature line from the content being verified
  awk '!/^#sig\b/' "$meta" >"$tmp"
  if [ "$META_SIG_ALGO" = "sha256" ]; then
    if command -v sha256sum >/dev/null 2>&1; then expected=$(sha256sum <"$tmp" | awk '{print $1}')
    else expected=$(shasum -a 256 <"$tmp" | awk '{print $1}'); fi
  else
    if command -v md5sum >/dev/null 2>&1; then expected=$(md5sum <"$tmp" | awk '{print $1}')
    else expected=$(md5 <"$tmp" 2>/dev/null | awk '{print $1}'); fi
  fi
  rm -f "$tmp"
  [ "$expected" = "$stored" ]
}

write_meta() {
  # Writes meta manifest atomically, signs it (unless none), and appends audit trail.
  local meta="$1"; shift
  local tmp="${meta}.tmp" sig
  printf '%s\t%s\t%s\n' "$META_HEADER" "$META_VER" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$tmp"
  for line in "$@"; do printf '%s\n' "$line" >>"$tmp"; done
  # Audit trail (2.2): record run id
  printf '#run\t%s\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$tmp"
  # Append signature as final line unless disabled
  if [ "$META_SIG_ALGO" != "none" ] && [ -s "$tmp" ]; then
    if [ "$META_SIG_ALGO" = "sha256" ]; then
      if command -v sha256sum >/dev/null 2>&1; then sig=$(sha256sum <"$tmp" | awk '{print $1}')
      else sig=$(shasum -a 256 <"$tmp" | awk '{print $1}'); fi
    else
      if command -v md5sum >/dev/null 2>&1; then sig=$(md5sum <"$tmp" | awk '{print $1}')
      else sig=$(md5 <"$tmp" 2>/dev/null | awk '{print $1}'); fi
    fi
    printf '#sig\t%s\n' "$sig" >>"$tmp"
  fi
  mv -f "$tmp" "$meta" || { record_error "Failed to move $tmp -> $meta"; return 1; }
  return 0
}

with_lock() {
  # Use flock if available; no persistent lockfiles.
  local lockfile="$1"; shift
  if [ "$TOOL_flock" -eq 1 ]; then
    mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true
    : > "$lockfile" 2>/dev/null || true
    exec 9>"$lockfile" || { "$@"; return; }
    flock -x 9
    "$@"
    flock -u 9
    exec 9>&-
    rm -f -- "$lockfile" 2>/dev/null || true
  else
    record_error "Warning: flock not available; running without file locks (race possible)."
    "$@"
  fi
}

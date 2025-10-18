# fs.sh

_safe_name(){ local n="$1"; [ -n "$n" ] || printf '%s' '__DO_NOT_MATCH__'; }

build_exclusions() {
  MD5_EXCL=$(_safe_name "$MD5_FILENAME")
  META_EXCL=$(_safe_name "$META_FILENAME")
  LOG_EXCL=$(_safe_name "$LOG_FILENAME")
  LOCK_EXCL="${META_EXCL}${LOCK_SUFFIX}"
}

find_file_expr() {
  local d="$1"
  find "$d" -maxdepth 1 -type f \
    ! -name '.DS_Store' ! -name '._*' \
    ! -name "$MD5_EXCL" ! -name "$META_EXCL" ! -name "$LOG_EXCL" ! -name "$LOCK_EXCL" -print0
}

cleanup_leftover_locks() {
  local base_dir="$1"
  find "$base_dir" -type f -name "*${LOCK_SUFFIX}" -print0 2>/dev/null \
    | while IFS= read -r -d '' lf; do
        case "$lf" in *".meta.lock"*)
          if [ ! -s "$lf" ] || [ "$(find "$lf" -mtime +0 -print 2>/dev/null)" ]; then
            dbg "Removing leftover lock file $lf"
            rm -f -- "$lf" 2>/dev/null || dbg "Could not remove $lf"
          fi
        esac
      done
}

count_files(){ find_file_expr "$1" | tr -cd '\0' | wc -c; }

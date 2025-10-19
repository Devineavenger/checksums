#!/usr/bin/env bash
# loader.sh
#
# Library loader for checksums v3.0.
# Searches candidate lib directories and sources all .sh files,
# but skips init.sh and loader.sh themselves to avoid recursion.
#
# This keeps parity with v2.12.5 behavior where the script could be
# installed in /usr/local/bin while its libraries lived in /usr/local/share/checksums/lib.

CANDIDATES=(
  "$BASE_DIR/lib"
  "/usr/local/share/checksums/lib"
  "/usr/share/checksums/lib"
)

sourced_any=0
# Tell ShellCheck we intentionally source dynamic files from lib paths
# shellcheck source=/dev/null
for cand in "${CANDIDATES[@]}"; do
  if [ -d "$cand" ]; then
    for lib in "$cand"/*.sh; do
      case "$(basename "$lib")" in
        init.sh|loader.sh) continue ;;  # skip self to prevent infinite loop
      esac
      [ -f "$lib" ] && . "$lib"
    done
    sourced_any=1
    break
  fi
done

if [ "$sourced_any" -eq 0 ]; then
  echo "FATAL: no library files found; expected under one of:" >&2
  printf '  %s\n' "${CANDIDATES[@]}" >&2
  exit 2
fi

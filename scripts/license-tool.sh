#!/bin/sh
# scripts/license-tool.sh
# POSIX shell. Usage: license-tool.sh <command> <path>
# Commands:
#   newfile <file>
#   addheader <file>
#   addheaders <dir>
#   addheaders-recursive <dir>
# Expects LICENSE_HEADER in the environment (multi-line allowed).
set -eu

usage() {
    cat <<EOF >&2
Usage:
  $0 newfile <file>
  $0 addheader <file>
  $0 addheaders <dir>
  $0 addheaders-recursive <dir>

Requires LICENSE_HEADER in the environment.
EOF
    exit 2
}

: "${LICENSE_HEADER:?LICENSE_HEADER must be set in the environment (use Makefile to export it)}"

is_text_file() {
    if command -v grep >/dev/null 2>&1; then
        grep -Iq . "$1" >/dev/null 2>&1
    else
        return 0
    fi
}

prepend_header_to_file() {
    file="$1"

    if [ ! -e "$file" ]; then
        echo "Error: file not found: $file" >&2
        return 3
    fi

    if ! is_text_file "$file"; then
        echo "Skipped (binary or non-text): $file"
        return 0
    fi

    # Check only the top of the file for SPDX to avoid false positives later in file
    if head -n 20 "$file" | grep -qE '^[[:space:]]*#?[[:space:]]*SPDX-License-Identifier:'; then
        echo "Skipped (already has header): $file"
        return 0
    fi

    # Simple per-file lock to avoid concurrent races
    lockdir="${file}.lock"
    if ! mkdir "$lockdir" 2>/dev/null; then
        echo "Skipped (locked by another process): $file"
        return 0
    fi
    trap 'rmdir "$lockdir"' EXIT INT TERM

    dir="$(dirname -- "$file")"
    tmp="$(mktemp "${dir}/.license.tmp.XXXXXX")"
    trap 'rm -f "$tmp"; rmdir "$lockdir"' EXIT INT TERM

    # Write header and append original content
    printf "%b" "$LICENSE_HEADER" > "$tmp"
    # Ensure a single blank line between header and content if header doesn't end with newline
    cat "$file" >> "$tmp"

    mv "$tmp" "$file"
    # best-effort preserve mode (ignore errors)
    chmod --reference="$file" "$file" 2>/dev/null || true

    trap - EXIT
    echo "Prepended license header to: $file"
    return 0
}

create_newfile_with_header() {
    file="$1"
    if [ -e "$file" ]; then
        echo "Error: file already exists: $file" >&2
        return 4
    fi
    dir="$(dirname -- "$file")"
    [ -d "$dir" ] || mkdir -p "$dir"
    tmp="$(mktemp "${dir}/.license.new.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT INT TERM
    printf "%b\n\n" "$LICENSE_HEADER" > "$tmp"
    echo "# Your code starts below" >> "$tmp"
    mv "$tmp" "$file"
    chmod 0644 "$file" 2>/dev/null || true
    trap - EXIT
    echo "Created new file with license header: $file"
    return 0
}

if [ $# -lt 2 ]; then
    usage
fi

cmd="$1"
shift

case "$cmd" in
    newfile)
        create_newfile_with_header "$1"
        ;;

    addheader)
        prepend_header_to_file "$1"
        ;;

    addheaders)
        dir="$1"
        for f in "$dir"/*; do
            [ -e "$f" ] || continue
            [ -f "$f" ] || continue
            prepend_header_to_file "$f"
        done
        ;;

    addheaders-recursive)
        dir="$1"
        find "$dir" -type f \( -name "*.md" -o -name "*.sh" -o -name "Makefile" \) -print0 |
            while IFS= read -r -d '' f; do
                prepend_header_to_file "$f"
            done
        ;;

    *)
        echo "Unknown command: $cmd" >&2
        usage
        ;;
esac

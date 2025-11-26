#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

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

Requires LICENSE_HEADER in the environment or a path in LICENSE_HEADER_FILE.
EOF
    exit 2
}

# Prefer reading the license header from a file to avoid exporting large multi-line env vars.
# If LICENSE_HEADER_FILE is set and points to a file, read it into LICENSE_HEADER.
if [ -n "${LICENSE_HEADER_FILE:-}" ] && [ -f "$LICENSE_HEADER_FILE" ]; then
    LICENSE_HEADER="$(cat "$LICENSE_HEADER_FILE")"
fi

: "${LICENSE_HEADER:?LICENSE_HEADER must be set in the environment or via LICENSE_HEADER_FILE (set LICENSE_HEADER_FILE to scripts/LICENSE)}"

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

    dir="$(dirname -- "$file")"
    tmp="$(mktemp "${dir}/.license.tmp.XXXXXX")"

    cleanup() {
        [ -n "${tmp:-}" ] && [ -f "$tmp" ] && rm -f "$tmp" || true
        [ -n "${lockdir:-}" ] && [ -d "$lockdir" ] && rmdir "$lockdir" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    # If the file starts with a shebang, preserve it as the first line.
    # Write shebang (if present), then header, then the rest of the file.
    first_line="$(head -n1 "$file" 2>/dev/null || true)"
    if [ "${first_line#\#!}" != "$first_line" ]; then
        # file has a shebang; write it first and then the header and the rest
        printf '%s\n' "$first_line" > "$tmp"
        printf "%b\n\n" "$LICENSE_HEADER" >> "$tmp"
        # append the rest of the file (skip the first line)
        tail -n +2 "$file" >> "$tmp"
    else
        # no shebang: header goes at the very top
        printf "%b\n\n" "$LICENSE_HEADER" > "$tmp"
        cat "$file" >> "$tmp"
    fi

    # Preserve original file mode by applying it to the temp file before moving it into place.
    chmod --reference="$file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"

    # Explicit cleanup (trap will also run on unexpected exit)
    cleanup
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

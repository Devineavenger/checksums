# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# checksums.bash — Bash tab-completion for the checksums CLI tool.
#
# Installation:
#   Source this file directly:         source checksums.bash
#   Or install to system completions:  install -m 0644 checksums.bash \
#       $(pkg-config --variable=completionsdir bash-completion 2>/dev/null \
#         || echo /usr/local/share/bash-completion/completions)/checksums
#
# Requires the bash-completion framework for full functionality (_init_completion,
# _filedir). Falls back to basic COMP_WORDS parsing when the framework is absent.

# shellcheck disable=SC2034  # words/cword are set by _init_completion for framework use
# shellcheck disable=SC2207  # COMPREPLY=( $(compgen ...) ) is the standard bash-completion idiom

# _checksums — Main completion function.
#
# Dispatches on the previous word ($prev) to provide context-sensitive completions
# for flags that accept enumerated or typed values. When the current word starts
# with a dash, offers all known short and long flags. Otherwise falls back to
# directory completion for the positional DIRECTORY argument.
_checksums() {
    local cur prev words cword

    # Use bash-completion's _init_completion when available (handles quoting,
    # redirections, etc.). Fall back to manual COMP_WORDS parsing otherwise.
    if declare -F _init_completion >/dev/null 2>&1; then
        _init_completion || return
    else
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
    fi

    # Context-sensitive value completion based on the preceding flag.
    case "$prev" in
        -a|--per-file-algo)
            # Per-file checksum algorithms. Comma-separated multi-algo supported
            # (e.g. md5,sha256) — complete individual names; user types the comma.
            COMPREPLY=( $(compgen -W "md5 sha1 sha224 sha256 sha384 sha512" -- "$cur") )
            return
            ;;
        -m|--meta-sig)
            # Meta-signature algorithm for .meta file integrity.
            COMPREPLY=( $(compgen -W "sha256 md5 none" -- "$cur") )
            return
            ;;
        -o|--output|--log-format)
            # Per-directory log output format.
            COMPREPLY=( $(compgen -W "text json csv" -- "$cur") )
            return
            ;;
        -C|--first-run-choice)
            # First-run mismatch handling strategy.
            COMPREPLY=( $(compgen -W "skip overwrite prompt" -- "$cur") )
            return
            ;;
        -c|--check|--config)
            # File path completion (manifest file or config file).
            if declare -F _filedir >/dev/null 2>&1; then
                _filedir
            else
                COMPREPLY=( $(compgen -f -- "$cur") )
            fi
            return
            ;;
        -D|--store-dir)
            # Directory-only completion for central manifest store path.
            if declare -F _filedir >/dev/null 2>&1; then
                _filedir -d
            else
                COMPREPLY=( $(compgen -d -- "$cur") )
            fi
            return
            ;;
        -p|--parallel|-P|--parallel-dirs)
            # Parallel jobs/dirs: integer, "auto", or fraction (e.g. 3/4).
            # Offer common values; user can type any number freely.
            COMPREPLY=( $(compgen -W "auto 1 2 4 8" -- "$cur") )
            return
            ;;
        -f|--base-name|-l|--log-base|-b|--batch|-e|--exclude|-i|--include|--max-size|--min-size)
            # Free-form text values — no specific completions to offer.
            return
            ;;
    esac

    # Flag completion when the current word starts with a dash.
    if [[ "$cur" == -* ]]; then
        local flags="
            -h --help --version --config
            -f --base-name -l --log-base -D --store-dir
            -a --per-file-algo -m --meta-sig -R --no-reuse
            -p --parallel -P --parallel-dirs -b --batch
            -n --dry-run -d --debug -v --verbose
            -r --force-rebuild -y --assume-yes --assume-no
            -q --quiet -Q --no-progress -M --minimal
            -F --first-run -C --first-run-choice -K --first-run-keep
            -V --verify-only -c --check
            -z --no-md5-details --md5-details
            -S --status
            -o --output
            --skip-empty --no-skip-empty --allow-root-sidefiles
            -L --follow-symlinks --no-follow-symlinks
            -e --exclude -i --include --max-size --min-size
        "
        COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
        return
    fi

    # Default: directory completion for the positional DIRECTORY argument.
    if declare -F _filedir >/dev/null 2>&1; then
        _filedir -d
    else
        COMPREPLY=( $(compgen -d -- "$cur") )
    fi
}

# Register the completion function for the checksums command.
# -o default: fall through to readline defaults when no match is generated.
complete -o default -F _checksums checksums

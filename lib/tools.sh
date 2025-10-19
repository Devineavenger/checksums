#!/usr/bin/env bash
# tools.sh
# Tool detection and preflight checks; preserves original hints and messaging.

detect_tools() {
  if command -v md5sum >/dev/null 2>&1; then TOOL_md5_cmd="md5sum"; elif command -v md5 >/dev/null 2>&1; then TOOL_md5_cmd="md5 -r"; fi
  if command -v sha256sum >/dev/null 2>&1; then TOOL_sha256="sha256sum"; fi
  if command -v shasum >/dev/null 2>&1 && [ -z "$TOOL_sha256" ]; then TOOL_shasum="shasum -a 256"; fi
  if stat --version >/dev/null 2>&1; then TOOL_stat_gnu=1; else TOOL_stat_gnu=0; fi
  if command -v flock >/dev/null 2>&1; then TOOL_flock=1; else TOOL_flock=0; fi
  dbg "detected tools: md5='${TOOL_md5_cmd:-none}' sha256='${TOOL_sha256:-${TOOL_shasum:-none}}' flock=$TOOL_flock stat_gnu=$TOOL_stat_gnu"
}

install_hints() {
  cat <<'HINTS'
Install hints by OS family:

- Debian / Ubuntu:
  sudo apt update && sudo apt install -y coreutils

- Arch / Manjaro:
  sudo pacman -Syu coreutils

- Fedora / CentOS / RHEL:
  sudo dnf install -y coreutils

- openSUSE:
  sudo zypper install -y coreutils

- NixOS:
  nix profile install nixpkgs#coreutils

- macOS (Homebrew):
  brew install coreutils

Notes: macOS ships md5 and shasum; GNU coreutils provides md5sum/sha256sum.
HINTS
}

check_required_tools() {
  local missing=()
  # per-file hashing
  if [ "$PER_FILE_ALGO" = "md5" ]; then
    [ -n "$TOOL_md5_cmd" ] || missing+=("md5sum/md5")
  else
    [ -n "$TOOL_sha256" ] || [ -n "$TOOL_shasum" ] || missing+=("sha256sum/shasum")
  fi
  # meta signature
  if [ "$META_SIG_ALGO" = "sha256" ]; then
    [ -n "$TOOL_sha256" ] || [ -n "$TOOL_shasum" ] || missing+=("sha256sum/shasum")
  elif [ "$META_SIG_ALGO" = "md5" ]; then
    [ -n "$TOOL_md5_cmd" ] || missing+=("md5sum/md5")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    record_error "Missing required tools: ${missing[*]}"
    _global_log 1 "Tool installation hints:"
    install_hints
    return 1
  fi
  return 0
}

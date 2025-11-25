#!/usr/bin/env bash
# usage.sh
#
# Prints CLI usage, kept aligned with previous versions, expanded for 2.1/2.2/2.3 features.
# v2.3.1 adds --config FILE and default <BASE_NAME>.conf loading.
# v3.0 adds --skip-empty and --allow-root-sidefiles options.

usage() {
  cat <<EOF
$ME Version $VER

Usage: $ME [options] DIRECTORY

Options:
  -f NAME            base name for files (default: ${BASE_NAME})
  -a ALGO            per-file checksum algorithm: md5 (default) or sha256
  -m ALGO            meta signature algorithm: sha256 (default), md5, or none
  -l LOGNAME         log base name (default: same as -f)
  -n                 dry-run (no writes)
  -d                 debug (repeat for more)
  -v                 verbose
  -r                 force rebuild (ignore cheap checks and manifest)
  -R                 disable reuse heuristics; always recompute file hashes
  --no-reuse         same as -R
  -F                 first-run verify existing .md5 files that lack .meta/.log
  -C CHOICE          first-run choice: skip | overwrite | prompt (default prompt)
  -p N               parallel hashing jobs (default 1)
  -b RULES           adaptive batching rules (default: "0-2M:20,2M-50M:10,>50M:1")
                     format: "LOW-HIGH:COUNT,LOW-HIGH:COUNT,>HIGH:COUNT"
                     units: K/M/G suffix supported (e.g. 512K, 2M, 1G).
  --batch RULES      same as -b, long form
  -o FORMAT          log format: text (default), json, csv
  -V                 verify-only mode (audit; no writes)
  -y                 yes (skip confirmation)
  -z                 disable per-directory MD5-details (same as --no-md5-details)
  --md5-details      when planning, run md5 verification for .md5-only directories and record MISSING/MISMATCH details in the run log (enabled by default)
  --no-md5-details   disable per-directory MD5-details (same as -z)
  --assume-yes       assume "yes" for all prompts (non-interactive)
  --assume-no        assume "no" for all prompts (non-interactive)
  --config FILE      load configuration from FILE (overrides default)
  --skip-empty       treat directories with no files anywhere under them as skipped (default)
  --no-skip-empty    disable skip-empty; process empty/container-only directories too
  --allow-root-sidefiles
                     allow per-directory sidecar files (.md5/.meta/.log) to be created in the root DIRECTORY.
                     by default the tool keeps the root clean; pass this flag to permit sidecar artifacts in root.
  --version          show version and exit
  -h                 help

Config file:
  By default, the tool looks for a config named "<BASE_NAME>.conf" in the root DIRECTORY.
  With the default BASE_NAME ("#####checksums#####"), this is "#####checksums#####.conf".
  Use --config FILE to specify an alternate path.
  The config file is sourced as shell, so you can set variables directly.
  CLI arguments always override config settings.

Patterns:
  INCLUDE_PATTERNS, EXCLUDE_PATTERNS accept shell globs (e.g., "*.tmp") to include/exclude files.
  If INCLUDE_PATTERNS is non-empty, only matching files are considered (after exclusions).

Examples:
  $ME -a sha256 -o json --assume-yes /data/project
  $ME --config /data/project/custom.conf -V /data/project
  $ME --allow-root-sidefiles /data/project   # permit per-dir artifacts in the project root
EOF
}

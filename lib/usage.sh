# usage.sh

usage() {
  cat <<EOF
$ME Version $VER

Usage: $ME [options] DIRECTORY

Options:
  -f NAME       base name for files (default: ${BASE_NAME})
  -a ALGO       per-file checksum algorithm: md5 (default) or sha256
  -m ALGO       meta signature algorithm: sha256 (default), md5, or none
  -l LOGNAME    log base name (default: same as -f)
  -n            dry-run (no writes)
  -d            debug (repeat for more)
  -v            verbose
  -r            force rebuild (ignore cheap checks and manifest)
  -F            first-run verify existing .md5 files that lack .meta/.log
  -C CHOICE     first-run choice: skip | overwrite | prompt (default prompt)
  -p N          parallel hashing jobs (default 1)
  -y            yes (skip confirmation)
  -V            show version and exit
  -h            help
EOF
}

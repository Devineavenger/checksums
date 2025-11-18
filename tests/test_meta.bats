#!/usr/bin/env bats
load '../lib/meta.sh'

setup() {
  TMPDIR=$(mktemp -d)
  META_FILENAME="#####checksums#####.meta"
}

teardown() { rm -rf "$TMPDIR"; }

@test "write_meta and verify_meta_sig succeed with sha256" {
  metaf="$TMPDIR/$META_FILENAME"
  line="file.txt\t1\t1\t123\t3\tabcdef"
  write_meta "$metaf" "$line"
  run verify_meta_sig "$metaf"
  [ "$status" -eq 0 ]
}

@test "verify_meta_sig fails with invalid signature" {
  metaf="$TMPDIR/$META_FILENAME"
  echo -e "#meta\tv1\t2025-01-01T00:00:00Z\nfoo\t1\t1\t123\t3\tdeadbeef\n#sig\tbad" > "$metaf"
  run verify_meta_sig "$metaf"
  [ "$status" -ne 0 ]
}

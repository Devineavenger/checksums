#!/usr/bin/env bash
set -euo pipefail

TESTDIR="random-dir"
RESULTS="benchmark_results.csv"

# === Step 1: Create synthetic dataset if missing ===
mkdir -p "$TESTDIR"
echo "Checking synthetic dataset in $TESTDIR..."

# 1000 files of 100 KB
if [ "$(ls "$TESTDIR"/file_100k_* 2>/dev/null | wc -l)" -lt 1000 ]; then
  echo "Creating 1000 x 100KB files..."
  for i in $(seq 1 1000); do
    [ -f "$TESTDIR/file_100k_$i.bin" ] || \
      dd if=/dev/urandom of="$TESTDIR/file_100k_$i.bin" bs=100K count=1 status=none
  done
fi

# 1000 files of 1 MB
if [ "$(ls "$TESTDIR"/file_1M_* 2>/dev/null | wc -l)" -lt 1000 ]; then
  echo "Creating 1000 x 1MB files..."
  for i in $(seq 1 1000); do
    [ -f "$TESTDIR/file_1M_$i.bin" ] || \
      dd if=/dev/urandom of="$TESTDIR/file_1M_$i.bin" bs=1M count=1 status=none
  done
fi

# 200 files of 10 MB
if [ "$(ls "$TESTDIR"/file_10M_* 2>/dev/null | wc -l)" -lt 200 ]; then
  echo "Creating 200 x 10MB files..."
  for i in $(seq 1 200); do
    [ -f "$TESTDIR/file_10M_$i.bin" ] || \
      dd if=/dev/urandom of="$TESTDIR/file_10M_$i.bin" bs=10M count=1 status=none
  done
fi

# 100 files of 40 MB
if [ "$(ls "$TESTDIR"/file_40M_* 2>/dev/null | wc -l)" -lt 100 ]; then
  echo "Creating 100 x 40MB files..."
  for i in $(seq 1 100); do
    [ -f "$TESTDIR/file_40M_$i.bin" ] || \
      dd if=/dev/urandom of="$TESTDIR/file_40M_$i.bin" bs=40M count=1 status=none
  done
fi

# 100 files of 100 MB
if [ "$(ls "$TESTDIR"/file_100M_* 2>/dev/null | wc -l)" -lt 100 ]; then
  echo "Creating 100 x 100MB files..."
  for i in $(seq 1 100); do
    [ -f "$TESTDIR/file_100M_$i.bin" ] || \
      dd if=/dev/urandom of="$TESTDIR/file_100M_$i.bin" bs=100M count=1 status=none
  done
fi

# === Step 1b: Report dataset size ===
DATASET_SIZE=$(du -sh "$TESTDIR" | cut -f1)
echo "Dataset ready (total size: $DATASET_SIZE)."

DATASET_BYTES=$(find "$TESTDIR" -type f -printf "%s\n" | awk '{sum+=$1} END {print sum}')

if [ "$DATASET_BYTES" -ge $((1024*1024)) ]; then
  # Show in MB with 2 decimals
  DATASET_HUMAN=$(echo "scale=2; $DATASET_BYTES/1024/1024" | bc)
  echo "Dataset ready (no overhead) (total size: ${DATASET_HUMAN} MB)"
elif [ "$DATASET_BYTES" -ge 1024 ]; then
  # Show in KB
  DATASET_HUMAN=$(echo "scale=2; $DATASET_BYTES/1024" | bc)
  echo "Dataset ready (no overhead) (total size: ${DATASET_HUMAN} KB)"
else
  # Show in bytes
  echo "Dataset ready (no overhead) (total size: ${DATASET_BYTES} B)"
fi

# === Step 2: Initialize results file ===
echo "p,b,c,d,elapsed" > "$RESULTS"

# === Step 3: Sweep parameters ===
for p in 16 8 6 4 2 1; do
  for b in 1 5 10 20; do
    for c in 1 5 10 20; do
      for d in 1 5; do
        rules="0-2M:$b,2M-50M:$c,>50M:$d"
        echo "DEBUG: starting run p=$p b=$b c=$c d=$d rules=$rules"

        # Drop caches so the next run reads from disk, not RAM
        sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'

        # Run checksums with forced recomputation (-r), non-interactive (-y),
        # and allow root sidefiles so TESTDIR itself is processed.
        elapsed=$( PATH="/tmp/bin:$PATH" /usr/bin/time -f "%e" \
          checksums -v -r -R -y --allow-root-sidefiles -p "$p" --batch "$rules" "$TESTDIR" \
          2>&1 >/dev/null || echo "ERR" )

        echo "DEBUG: finished run p=$p b=$b c=$c d=$d elapsed=$elapsed"
        echo "$p,$b,$c,$d,$elapsed" >> "$RESULTS"

        # Optional: sanity check that the run actually processed files.
        RUNLOG="$TESTDIR/#####checksums#####.run.log"
        if [ -f "$RUNLOG" ]; then
          tail -n 5 "$RUNLOG" | sed 's/^/DEBUG LOG: /'
        else
          echo "DEBUG: run log not found at $RUNLOG"
        fi
      done
    done
  done
done

echo "Benchmark complete. Results in $RESULTS"

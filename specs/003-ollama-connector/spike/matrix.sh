#!/bin/sh
# Spike S2 matrix (task T002). Synthetic picture only.
cd "$(dirname "$0")"
: > results.jsonl
for mode_runs in "native 5" "fallback 3"; do
  mode=${mode_runs% *}; runs=${mode_runs#* }
  for think in false true; do
    for size in 1024 1536 2048 3072 4096; do
      ./spike003 --size $size --think $think --mode $mode --format jpeg --runs $runs --label "$mode" --timeout 900 >> results.jsonl
    done
  done
done
echo done > matrix.done

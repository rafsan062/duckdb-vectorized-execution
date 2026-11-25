#!/bin/bash
# Per-operator time breakdown (Figure 7) using DuckDB's JSON profiler.
# Usage: bash benchmarks/profile_operators.sh [rows] [runs]   (defaults 10000000, 3)
# Each run is a separate process: one unprofiled warm-up query, then one profiled query.
# The profiler times every operator call, which adds overhead (more calls at small
# vector sizes), so use these for each operator's share of time, not for totals.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
builds_dir="$project_dir/../duckdb/build"
rows="${1:-10000000}"; runs="${2:-3}"
query="${QUERY:-SELECT SUM(quantity * unit_price) AS revenue FROM cafe_sales WHERE quantity >= 2;}"
out_dir="$project_dir/benchmarks/results/profile-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out_dir"
vector_size_of() { sed -n 's/^vector_size=//p' "$builds_dir/$1/variant.txt"; }

for bin in "$builds_dir"/bench-*/duckdb; do
  name="$(basename "$(dirname "$bin")")"
  db="$project_dir/benchmarks/data/vs$(vector_size_of "$name")/cafe-$rows.duckdb"
  for ((k = 1; k <= runs; k++)); do
    printf 'SET threads = 1;\n%s\nPRAGMA enable_profiling = '"'"'json'"'"';\nPRAGMA profiling_output = '"'"'%s'"'"';\n%s\n' \
      "$query" "$out_dir/$name-run$k.json" "$query" \
      | "$bin" -no-agent -readonly "$db" > /dev/null
  done
  printf '%s profiled\n' "$name"
done
printf 'Results in %s\n' "$out_dir"

#!/bin/bash
# Generate the benchmark databases, one set per vector size.
# DuckDB records the vector size in the database file header and refuses to open
# a file written with a different size (src/storage/single_file_block_manager.cpp:369-372),
# so each vector size gets its own files, written by that size's SIMD-on build.
# The generator is deterministic, so the data is the same; SIMD on/off builds of
# the same vector size read the identical file.
# Usage: bash benchmarks/prepare_data.sh [rows]   (default 10000000)
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
builds_dir="$project_dir/../duckdb/build"
rows="${1:-10000000}"
data_root="$project_dir/benchmarks/data"

vector_size_of() { sed -n 's/^vector_size=//p' "$builds_dir/$1/variant.txt"; }

# Generate with each vector size's SIMD-on build.
for gen in "$builds_dir"/bench-*-simdon/duckdb; do
  name="$(basename "$(dirname "$gen")")"
  dir="$data_root/vs$(vector_size_of "$name")"
  mkdir -p "$dir"
  [[ -e "$dir/cafe-10k.duckdb" ]] || DUCKDB_BIN="$gen" bash "$project_dir/dataset/generate.sh" 10000 "$dir/cafe-10k.duckdb"
  [[ -e "$dir/cafe-$rows.duckdb" ]] || DUCKDB_BIN="$gen" bash "$project_dir/dataset/generate.sh" "$rows" "$dir/cafe-$rows.duckdb"
done

# Every build must agree on the answers.
{
  printf 'build,database,row_count,revenue\n'
  for bin in "$builds_dir"/bench-*/duckdb; do
    name="$(basename "$(dirname "$bin")")"
    dir="$data_root/vs$(vector_size_of "$name")"
    for db in "$dir/cafe-10k.duckdb" "$dir/cafe-$rows.duckdb"; do
      out="$("$bin" -no-agent -readonly -csv -noheader "$db" \
        -c "SELECT COUNT(*), (SELECT SUM(quantity * unit_price) FROM cafe_sales WHERE quantity >= 2) FROM cafe_sales;")"
      printf '%s,%s,%s\n' "$name" "vs$(vector_size_of "$name")/$(basename "$db")" "$out"
    done
  done
} | tee "$data_root/correctness.csv"

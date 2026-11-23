#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
duckdb_bin="${DUCKDB_BIN:-$project_dir/../duckdb/build/debug/duckdb}"
count="${1:-10000}"
database="${2:-$project_dir/dataset/cafe-10k.duckdb}"
if ! [[ "$count" =~ ^[0-9]+$ ]]; then
  printf 'Row count must be a nonnegative integer.\n' >&2
  exit 1
fi
if [[ -e "$database" || -e "$database.wal" ]]; then
  printf 'Refusing to overwrite existing database or WAL: %s\n' "$database" >&2
  exit 1
fi
{ printf 'SET VARIABLE transaction_count = %s;\n' "$count"; cat "$project_dir/dataset/generate_data.sql"; } | "$duckdb_bin" -no-agent "$database"

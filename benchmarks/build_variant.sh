#!/bin/bash
# Build one DuckDB release variant for the benchmarks.
# Usage: bash benchmarks/build_variant.sh <vector_size> <simd: on|off>
# Output: ../duckdb/build/bench-vs<vector_size>-simd<on|off>/duckdb
# Leaves the existing ../duckdb/build/release and build/debug untouched.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
duckdb_src="${DUCKDB_SRC:-$project_dir/../duckdb}"
expected_commit=87d96b7773a10356b11cc15c352125acdc58a9ce

vs="${1:?vector size required (power of two, e.g. 2 or 2048)}"
simd="${2:?simd on|off required}"
if ! [[ "$vs" =~ ^[0-9]+$ ]] || (( vs < 1 || (vs & (vs - 1)) != 0 )); then
  printf 'Vector size must be a power of two: %s\n' "$vs" >&2; exit 1
fi
case "$simd" in
  on)  flags="" ;;
  off) flags="-fno-vectorize -fno-slp-vectorize" ;;   # clang: disable loop and SLP auto-vectorization
  *)   printf 'simd must be on or off: %s\n' "$simd" >&2; exit 1 ;;
esac

actual_commit="$(git -C "$duckdb_src" rev-parse HEAD)"
if [[ "$actual_commit" != "$expected_commit" ]]; then
  printf 'DuckDB checkout is at %s, expected %s\n' "$actual_commit" "$expected_commit" >&2; exit 1
fi

name="bench-vs${vs}-simd${simd}"
out="$duckdb_src/build/$name"
mkdir -p "$out"
start=$(date +%s)
cmake -S "$duckdb_src" -B "$out" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags" \
  -DSTANDARD_VECTOR_SIZE="$vs" \
  -DBUILD_EXTENSIONS=core_functions \
  -DSKIP_EXTENSIONS="parquet;json;icu" \
  -DBUILD_UNITTESTS=OFF > "$out/cmake.log"
ninja -C "$out" duckdb
elapsed=$(( $(date +%s) - start ))

# Record what was built, for Table 5.1.
{
  printf 'name=%s\nvector_size=%s\nsimd=%s\nflags=%s\n' "$name" "$vs" "$simd" "$flags"
  printf 'commit=%s\ncompiler=%s\n' "$actual_commit" "$(c++ --version | head -1)"
  printf 'sha256=%s\nbuild_seconds=%s\n' "$(shasum -a 256 "$out/duckdb" | cut -d' ' -f1)" "$elapsed"
} | tee "$out/variant.txt"

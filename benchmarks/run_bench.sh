#!/bin/bash
# Time the baseline query on every built variant.
# Usage: bash benchmarks/run_bench.sh [rows] [rounds] [repeats] [warmup]
#   rows      which generated database to use (default 10000000); each build reads
#             benchmarks/data/vs<its vector size>/cafe-<rows>.duckdb
#   rounds    separate processes per build, interleaved across builds (default 5)
#   repeats   timed queries per process after warm-up (default 10)
#   warmup    untimed queries per process first (default 2)
# Each round runs, for every build, a "long" process (warmup + repeats queries)
# and a "short" process (warmup queries only). Instructions and cycles per query
# = (long - short) / repeats, which removes startup and database-open cost.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
builds_dir="$project_dir/../duckdb/build"
rows="${1:-10000000}"
data_root="$project_dir/benchmarks/data"
vector_size_of() { sed -n 's/^vector_size=//p' "$builds_dir/$1/variant.txt"; }
rounds="${2:-5}"; repeats="${3:-10}"; warmup="${4:-2}"
query="${QUERY:-SELECT SUM(quantity * unit_price) AS revenue FROM cafe_sales WHERE quantity >= 2;}"
threads="${THREADS:-1}"

for bin in "$builds_dir"/bench-*/duckdb; do
  name="$(basename "$(dirname "$bin")")"
  db="$data_root/vs$(vector_size_of "$name")/cafe-$rows.duckdb"
  [[ -e "$db" ]] || { printf 'Missing database: %s (run prepare_data.sh %s)\n' "$db" "$rows" >&2; exit 1; }
done
out_dir="$project_dir/benchmarks/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out_dir"

session() {  # session <n_queries>
  # SET comes before .timer so that only the queries print "Run Time" lines.
  printf 'SET threads = %s;\n.mode csv\n.headers off\n.timer on 6\n' "$threads"
  local i; for ((i = 0; i < $1; i++)); do printf '%s\n' "$query"; done
}
session $((warmup + repeats)) > "$out_dir/long.sql"
session "$warmup" > "$out_dir/short.sql"

# Environment, for Table 5.1 and reproducibility.
{
  printf 'date=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'cpu=%s\n' "$(sysctl -n machdep.cpu.brand_string)"
  printf 'cores=%s\nmemory_bytes=%s\n' "$(sysctl -n hw.ncpu)" "$(sysctl -n hw.memsize)"
  printf 'os=%s %s\n' "$(sw_vers -productName)" "$(sw_vers -productVersion)"
  printf 'power=%s\n' "$(pmset -g batt | head -1)"
  printf 'commit=%s\n' "$(git -C "$project_dir/../duckdb" rev-parse HEAD)"
  printf 'rows=%s\nrounds=%s\nrepeats=%s\nwarmup=%s\nthreads=%s\nquery=%s\n' \
    "$rows" "$rounds" "$repeats" "$warmup" "$threads" "$query"
} > "$out_dir/env.txt"
for v in "$builds_dir"/bench-*/variant.txt; do
  printf '\n# %s\n' "$v"; cat "$v"
done >> "$out_dir/env.txt"

printf 'build,round,query_index,real_s,user_s,result\n' > "$out_dir/times.csv"
printf 'build,round,kind,instructions,cycles,peak_memory_bytes\n' > "$out_dir/counters.csv"

for ((r = 1; r <= rounds; r++)); do
  for bin in "$builds_dir"/bench-*/duckdb; do
    name="$(basename "$(dirname "$bin")")"
    db="$data_root/vs$(vector_size_of "$name")/cafe-$rows.duckdb"
    for kind in long short; do
      log="$out_dir/raw-$name-r$r-$kind"
      /usr/bin/time -l "$bin" -no-agent -readonly "$db" < "$out_dir/$kind.sql" > "$log.out" 2> "$log.time"
      awk -v b="$name" -v r="$r" -v k="$kind" '
        /instructions retired/ {ins=$1} /cycles elapsed/ {cyc=$1} /peak memory footprint/ {mem=$1}
        END {printf "%s,%s,%s,%s,%s,%s\n", b, r, k, ins, cyc, mem}' "$log.time" >> "$out_dir/counters.csv"
      if [[ "$kind" == long ]]; then
        # Output alternates: result line, then "Run Time (s): real X user Y sys Z".
        awk -v b="$name" -v r="$r" -v w="$warmup" '
          /^Run Time/ {q++; if (q > w) printf "%s,%s,%d,%s,%s,%s\n", b, r, q - w, $5, $7, res; next}
          {res=$0}' "$log.out" >> "$out_dir/times.csv"
      fi
    done
    printf 'round %s/%s  %s done\n' "$r" "$rounds" "$name"
  done
done
printf 'Results in %s\n' "$out_dir"

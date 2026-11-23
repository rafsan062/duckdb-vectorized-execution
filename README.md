# DuckDB Vectorized Execution

Research workspace for a CPSC 5300 project. The fictional Seattle University campus café dataset is synthetic; it does not represent real transactions.

## Setup

DuckDB source is expected in `../duckdb`, with a debug build at `../duckdb/build/debug/duckdb`. The investigated commit is `87d96b7773a10356b11cc15c352125acdc58a9ce`. For a new source checkout, run the following from this research repository (do not overwrite an existing `../duckdb`):

```sh
git clone https://github.com/duckdb/duckdb.git ../duckdb
git -C ../duckdb checkout --detach 87d96b7773a10356b11cc15c352125acdc58a9ce
git -C ../duckdb rev-parse HEAD
(cd ../duckdb && CMAKE_BUILD_PARALLEL_LEVEL=4 GEN=ninja make debug)
```

For an existing checkout, verify its commit and preserve any local work before changing it. DuckDB's [macOS build guide](https://duckdb.org/docs/current/dev/building/macos) describes the compiler, CMake, and Ninja prerequisites. The debug build can require substantial disk space. The DuckDB source and build are separate from this research repository.

From this directory, generate the default 10,000 rows in a new database and run the baseline query:

```sh
bash dataset/generate.sh
../duckdb/build/debug/duckdb -no-agent -readonly dataset/cafe-10k.duckdb < dataset/baseline.sql
```

The complete SQL can also be run directly against a new database:

```sh
../duckdb/build/debug/duckdb -no-agent dataset/cafe-10k.duckdb < dataset/generate_data.sql
```

Use either generation command, not both on the same database: the direct SQL creates `cafe_sales` and will fail if the table already exists.

Use `bash dataset/generate.sh 1000000 dataset/cafe-large.duckdb` to choose a different size and output path. Set `DUCKDB_BIN` to use another DuckDB executable. The generator refuses to overwrite an existing database or WAL. Generated databases are ignored by Git; the SQL script is the reproducible source.

`cafe_sales` contains `sale_id`, `item`, `quantity`, and `unit_price` (fixed-point decimal). Item names, quantities, and prices are determined by the sale ID, so generation is repeatable. See `dataset/baseline.sql` and `dataset/baseline-10k-plan.txt` for the query and its observed 10,000-row plan. The earlier 100,000-row database and plan, if present, are preserved separately.

For the default 10,000-row dataset, `SELECT COUNT(*) FROM cafe_sales;` returns **10000**, and the baseline query returns **126989.25**. Check both with:

```sh
../duckdb/build/debug/duckdb -no-agent -readonly dataset/cafe-10k.duckdb -c 'SELECT COUNT(*) AS row_count FROM cafe_sales;'
../duckdb/build/debug/duckdb -no-agent -readonly dataset/cafe-10k.duckdb < dataset/baseline.sql
```

To inspect the plan again:

```sh
../duckdb/build/debug/duckdb -no-agent -readonly dataset/cafe-10k.duckdb -c 'EXPLAIN SELECT SUM(quantity * unit_price) AS revenue FROM cafe_sales WHERE quantity >= 2;'
```

The `~` row counts in the plan are estimates. The dataset uses regular deterministic patterns and is not intended to model real café behavior.

## Responsibilities

- `dataset/`: shared synthetic data and SQL.
- `pipeline/`: Rizvan's pipeline and LLDB investigation.
- `pipeline/evidence/`: debugger transcripts supporting the investigation.
- `simd/`: Kevin's SIMD and assembly investigation.
- `benchmarks/`: Jeffrey's benchmark experiments.
- `writeup/`: research paper.
- `presentation/`: slides and demonstration.

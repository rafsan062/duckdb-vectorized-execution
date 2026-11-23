# Pipeline Architecture and DataChunk Flow

## A café query as an execution example

For a reader accustomed to SQLite's virtual machine, DuckDB's physical operators play a familiar role: they implement the work needed to scan, transform, and aggregate data. This section follows DuckDB's particular organization of that work into **pipelines** and its use of batches of column vectors. It does not claim that SQLite cannot process batches or make a performance comparison between the systems.

Our example uses a deterministic, fictional campus café dataset of 10,000 sales. The generator derives `item`, `quantity`, and fixed-point `unit_price` from `sale_id` (`dataset/generate_data.sql`). The baseline query is:

```sql
SELECT SUM(quantity * unit_price) AS revenue
FROM cafe_sales
WHERE quantity >= 2;
```

At DuckDB commit `87d96b7773a10356b11cc15c352125acdc58a9ce`, the recorded physical plan (`dataset/baseline-10k-plan.txt`) is, from input to output:

```text
Sequential scan: cafe_sales, filter quantity >= 2
    → Projection: CAST(quantity AS DECIMAL(18,0)) * CAST(unit_price AS DECIMAL(18,2))
    → Ungrouped aggregate: sum_no_overflow(#0)
```

The scan also projects `quantity` and `unit_price`. The plan estimates approximately 8,000 rows after filtering; that estimate is not itself a runtime measurement. The actual baseline query returned `126989.25`. The sections below distinguish what the source says from what we observed at selected debugger stops.

## Constructing pipelines

A pipeline organizes a source, zero or more intermediate operators, and a sink. The source supplies input, intermediate operators transform it, and the sink consumes the result. A pipeline task invokes `PipelineExecutor`, whose regular execution path fetches a chunk, runs intermediate operators, and passes a nonempty resulting chunk to the sink (`src/parallel/pipeline.cpp:52–71`; `src/parallel/pipeline_executor.cpp:383–385, 415, 575–598`).

```text
Input pipeline:       Scan + Filter → Projection → Aggregate Sink
                                                     ║
                                              pipeline boundary
                                                     ║
Downstream pipeline:                          Aggregate Source → Result
```

DuckDB builds this structure by walking the physical operator tree. In the following **selected source excerpt with omissions**, a leaf becomes a source; a sink starts a child meta-pipeline; and another operator is added to the current pipeline. The excerpt omits the intervening single-child check and comments.

`src/execution/physical_operator.cpp:245–274`:

```cpp
if (!IsSink() && children.empty()) {
    state.SetPipelineSource(current, *this);
    return;
}
// ... single-child check ...
if (IsSink()) {
    sink_state.reset();
    state.SetPipelineSource(current, *this);
    auto &child_meta_pipeline = meta_pipeline.CreateChildMetaPipeline(current, *this);
    child_meta_pipeline.Build(children[0].get());
    return;
}
state.AddPipelineOperator(current, *this);
children[0].get().BuildPipelines(current, meta_pipeline);
```

The first condition recognizes a leaf that is not a sink; `SetPipelineSource` assigns it and `return` ends that branch. For a sink, `sink_state.reset()` clears its previous state and `SetPipelineSource` makes it the current pipeline's source. `CreateChildMetaPipeline` creates a pipeline for its input; `Build` recursively organizes the child. Otherwise, `AddPipelineOperator` records an intermediate operator, and the final call continues the walk into its child.

The aggregate is both a sink and a source (`src/include/duckdb/execution/operator/aggregate/physical_ungrouped_aggregate.hpp:37–60`). Its sink consumes projected input; after aggregation, its source provides the result to a downstream pipeline. The child meta-pipeline is constructed with the aggregate as its sink, and the parent is made dependent on that child when the dependency mode requests it (`src/parallel/meta_pipeline.cpp:7–10, 108–125`). This boundary separates accumulation from reading the completed result. The code supports parallel work with local and global aggregate states; the following trace does not measure whether parallelism improves performance.

**Observed with LLDB.** In the independently reproduced construction trace, `this->type` was `UNGROUPED_AGGREGATE` at `physical_operator.cpp:259`, `PROJECTION` at line 273, and `TABLE_SCAN` at line 251. At the latter two stops, `current` had the same pipeline address in that run. These observations support the interpretation that the scan and projection belong to the aggregate's input pipeline. Addresses are process-specific, not stable identifiers. See `pipeline/evidence/lldb-trace.txt`, beginning at “Reproduction of user-reported seven-breakpoint workflow.”

## Chunks and the pushed-down filter

`DataChunk` is DuckDB's intermediate representation for a subset of a relation: it holds vectors with a shared logical row count (`src/include/duckdb/common/types/data_chunk.hpp:28–30, 44–59`). Rather than passing an individual tuple at each operator boundary, this path passes a chunk containing column vectors. The default standard vector size is 2,048 (`src/include/duckdb/common/vector_size.hpp:15–20`), although returned chunks may contain fewer rows after filtering or at the end of a scan.

The recorded plan places `quantity >= 2` inside the scan. DuckDB's table scan advertises filter pushdown (`src/function/table/table_scan.cpp:1366–1369, 1381–1383`), and the physical scan calls its table-function callback to obtain an output chunk (`src/execution/operator/scan/physical_table_scan.cpp:166–186`). In the row-group filtered path, the scan evaluates filters and builds a **selection vector**: positions identifying the rows to retain within the scanned vector. The implementation first applies the filter and then uses the selection for the remaining output columns.

`src/storage/table/row_group.cpp:1050–1053, 1072–1079, 1087–1091, 1095–1098` (noncontiguous excerpt; loop and branch lines omitted):

```cpp
auto &col_data = GetColumn(column_idx);
col_data.Filter(transaction, state.vector_index, state.column_scans[scan_idx], result_vector, sel,
                approved_tuple_count, filter.filter, table_filter_state);
// ... for returned filter columns ...
result.data[table_filter.scan_column_index].Slice(sel, approved_tuple_count);
// ... for remaining columns ...
auto &col_data = GetColumn(column);
state.column_scans[i].update_scan_type = options.update_type;
col_data.Select(transaction, state.vector_index, state.column_scans[i], result.data[i], sel,
                approved_tuple_count);
// ...
count = approved_tuple_count;
result.SetChildCardinality(count);
```

`GetColumn` selects the filtered column; `Filter` updates `sel` and `approved_tuple_count`. `Slice` applies those positions to returned filter columns. The second `GetColumn` and `update_scan_type` prepare each remaining column, and `Select` uses the same positions to obtain its values. Finally, `count` and `SetChildCardinality` make the approved row count the output chunk's cardinality.

The design lets the scan carry the same qualifying positions across columns, maintaining row alignment while restricting what the next operator sees. This is a source-based explanation, not a measured speedup or a claim that all other implementations must materialize rejected rows. The implementation also has paths for an empty selection and for filters simplified using statistics (`src/storage/table/row_group.cpp:763–788, 1055–1070`).

**Observed with LLDB.** In a separate filter trace, `approved_tuple_count` was 2,048 at line 1051 and 1,638 after the filter loop at line 1055, in the same scan state and thread. The first eight `sel.get_index()` results were `1, 2, 3, 4, 6, 7, 8, 9`; these are positions within that vector, not necessarily table-wide row IDs. The first two attempts stopped while LLDB was still preparing the multi-line call, so their unchanged count and initial indices are pre-filter values. The successful third attempt and those earlier stops are preserved in `pipeline/evidence/filter-trace.txt`.

## Projection and aggregate state

The projection evaluates the multiplication over its input chunk. In this commit, its implementation delegates the work to an expression executor:

`src/execution/operator/projection/physical_projection.cpp:50–55`:

```cpp
OperatorResultType PhysicalProjection::Execute(ExecutionContext &context, DataChunk &input, DataChunk &chunk,
                                               GlobalOperatorState &gstate, OperatorState &state_p) const {
    auto &state = state_p.Cast<ProjectionState>();
    state.executor.Execute(input, chunk);
    return OperatorResultType::NEED_MORE_INPUT;
}
```

`Cast<ProjectionState>()` retrieves the projection's execution state. `state.executor.Execute(input, chunk)` evaluates the expressions into the output chunk. `NEED_MORE_INPUT` tells the pipeline that this operator is ready for more input after processing the chunk.

The expression executor evaluates expressions into output vectors and sets their cardinality from the input (`src/execution/expression_executor.cpp:115–124`). The aggregate sink then receives that output and updates local state (`src/execution/operator/aggregate/physical_ungrouped_aggregate.cpp:376–388`). The aggregate's `Combine` merges local state into global state (`:436–448`); its source finalizes aggregate state into a one-row chunk (`:715–736`). Separate local states make it possible for the implementation to combine partial results; the trace does not establish the number of workers or the number of partial states for this query.

**Observed with LLDB.** At selected stops in the independently reproduced trace, scan output was 1,638 rows; projection input and output were each 1,638; aggregate sink input was 1,638; and the final aggregate output was one row. The query then printed `126989.25` and exited with status 0. The first three observations describe one selected chunk, not the complete 10,000-row scan. The student's previously reported manual results were the same, but the original manual transcript was not supplied. Neither trace establishes every chunk size, the aggregate's internal callback, or which fast or fallback filter implementation executed. Evidence: `pipeline/evidence/lldb-trace.txt` and `pipeline/evidence/filter-trace.txt`.

| Debugger stop | Independently verified observation | Evidence |
|---|---|---|
| Filter loop, `row_group.cpp:1051` and `:1055` | Approved count: 2,048 before, 1,638 after | `pipeline/evidence/filter-trace.txt`, third attempt |
| Scan output, `physical_table_scan.cpp:188` | Chunk size: 1,638 | `pipeline/evidence/lldb-trace.txt`, ordered reproduction |
| Projection, `physical_projection.cpp:53–54` | Input and output: 1,638 each | Same ordered reproduction |
| Aggregate sink, `physical_ungrouped_aggregate.cpp:387` | Input chunk: 1,638 | Same ordered reproduction |
| Aggregate source, `physical_ungrouped_aggregate.cpp:733` | Final output chunk: 1 row | Same ordered reproduction |

## Reproducing the demonstration

From the `duckdb-research` directory, first check the source revision. If the existing default database is unavailable, generate it with the script; the script refuses to overwrite an existing database. The SQL and script accept other sizes for later experiments.

```sh
git -C ../duckdb rev-parse HEAD
bash dataset/generate.sh                         # only if dataset/cafe-10k.duckdb does not exist
../duckdb/build/debug/duckdb -no-agent -readonly dataset/cafe-10k.duckdb \
  -c 'SELECT COUNT(*) AS row_count FROM cafe_sales;'
../duckdb/build/debug/duckdb -no-agent -readonly dataset/cafe-10k.duckdb < dataset/baseline.sql
```

Expected results for the default dataset are `10000` rows and revenue `126989.25`. To inspect the plan, run the same CLI with `-c 'EXPLAIN SELECT SUM(quantity * unit_price) AS revenue FROM cafe_sales WHERE quantity >= 2;'`.

The generation, count, baseline query, and EXPLAIN commands were checked in a temporary workspace using the documented sibling-directory layout. They produced the stated database path and results; a second generation attempt refused to overwrite it.

For an LLDB check, start from the DuckDB source root so relative source paths resolve:

```sh
cd ../duckdb
lldb -- build/debug/duckdb -no-agent -readonly ../duckdb-research/dataset/cafe-10k.duckdb \
  -c 'SELECT SUM(quantity * unit_price) AS revenue FROM cafe_sales WHERE quantity >= 2;'
```

At the LLDB prompt, set a one-shot breakpoint at `src/storage/table/row_group.cpp:1051`, run, and inspect `approved_tuple_count`. Then set a one-shot breakpoint at `row_group.cpp:1055`, continue, and inspect the count and `sel.get_index(0)` through `sel.get_index(7)`. For the existing dataset and build, the recorded run showed 2,048 before and 1,638 after, with the eight indices above. In LLDB syntax, for example, use `breakpoint set --one-shot true --file src/storage/table/row_group.cpp --line 1051`, `frame variable approved_tuple_count`, and `expression -- sel.get_index(0)`. The full seven-stop pipeline procedure and its actual commands are in the evidence files; timings, thread scheduling, addresses, and individual stop order can differ across runs.

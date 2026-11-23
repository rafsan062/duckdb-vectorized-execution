# Café baseline: C++ pipeline investigation

DuckDB commit: `87d96b7773a10356b11cc15c352125acdc58a9ce`. All source paths and line numbers below are relative to the sibling `duckdb/` checkout. This report combines the recorded `dataset/baseline-10k-plan.txt`, source inspection, and the independent LLDB reproduction in `pipeline/evidence/lldb-trace.txt`.

## Manual observations and independent reproduction

The student reported a manual investigation with operator types `UNGROUPED_AGGREGATE`, `PROJECTION`, and `TABLE_SCAN`, then chunk sizes of 1,638 at scan output, projection input/output, and aggregate input, and 1 at aggregate output. No original manual transcript was supplied; those claims are attributed to the student and are not treated as the transcript of this reproduction.

The independent reproduction used the existing debug binary and `cafe-10k.duckdb`, with one-shot breakpoints installed in the student's stated order. Actual LLDB stops and commands are in `evidence/lldb-trace.txt`, under “Reproduction of user-reported seven-breakpoint workflow”:

| Stop | Independently observed | Source interpretation |
|---|---|---|
| `physical_operator.cpp:259` | `this->type = UNGROUPED_AGGREGATE` | The aggregate reaches the sink decision; the following projection stop in the child pipeline is consistent with taking this branch (`src/execution/physical_operator.cpp:259`–`:268`). |
| `physical_operator.cpp:273` | `this->type = PROJECTION` | Projection is added as an intermediate operator (`:272`–`:274`). |
| `physical_operator.cpp:251` | `this->type = TABLE_SCAN` | Table scan is assigned as source (`:249`–`:251`). Projection and scan had the same `current` pipeline address in this run. |
| `physical_table_scan.cpp:188` | `chunk.size() = 1638` | The first observed scan callback has returned a 1,638-row chunk (`src/execution/operator/scan/physical_table_scan.cpp:185`–`:188`). |
| `physical_projection.cpp:53` then step over | `input.size() = 1638`; `chunk.size() = 1638` at line 54 | Expression execution preserved the observed chunk cardinality (`src/execution/operator/projection/physical_projection.cpp:50`–`:54`). |
| `physical_ungrouped_aggregate.cpp:387` | `chunk.size() = 1638` | That observed chunk reached the aggregate sink (`src/execution/operator/aggregate/physical_ungrouped_aggregate.cpp:376`–`:387`). |
| `physical_ungrouped_aggregate.cpp:733` | `chunk.size() = 1` | The finalized aggregate source returned a one-row chunk (`:726`–`:733`). |

The query then printed `126989.25` and exited with status 0. These observations match the student's reported values; no value discrepancy was found. They describe selected stops, not every input chunk or an independently counted total. The aggregate's `this` address matched at construction, sink, and final source stops in this run.

The transcript also preserves an earlier automated attempt for the original, broader breakpoint list. It resolved and ran those one-shot breakpoints, but its breakpoint-command configuration executed only `continue`, so it did not capture the intended variable values. That attempt does not establish filter-branch details, combine-state values, or a full chunk-by-chunk trace. The ordered seven-stop reproduction is the evidence for the table above.

## Verified: plan and data flow

The previously recorded `EXPLAIN` for `dataset/cafe-10k.duckdb` shows, bottom to top:

```text
Seq Scan: cafe_sales; projections quantity, unit_price; filter quantity >= 2
  → Projection: CAST(quantity AS DECIMAL(18,0)) * CAST(unit_price AS DECIMAL(18,2))
  → Ungrouped Aggregate: sum_no_overflow(#0)
```

The plan's approximately 8,000 rows are an estimate, not an observed chunk count. The prior baseline execution returned `126989.25` for the 10,000-row dataset; it was not a debugger observation.

- A `DataChunk` contains vectors and exposes its logical row count via `size()` (`src/include/duckdb/common/types/data_chunk.hpp:28`, `:50`, `:54`). The executor's regular loop fetches a source chunk, then pushes it downstream (`src/parallel/pipeline_executor.cpp:331`, `:383`–`:385`, `:415`). The source wrapper ultimately calls the source operator's `GetData` (`:829`–`:837`, `:860`–`:870`).
- The sequential scan is represented by `PhysicalTableScan`; its `GetDataInternal` dispatches the table-function callback (`src/execution/operator/scan/physical_table_scan.cpp:166`, `:177`–`:186`). The native sequential scan registers `TableScanFunc` and enables projection and filter pushdown (`src/function/table/table_scan.cpp:1182`–`:1184`, `:1366`–`:1369`, `:1381`–`:1383`). Its callback dispatches to the global scan state; the native state contains both persistent-scan and read-ahead paths (`:670`–`:695`).
- In the storage scan's filtered path, the predicate's column is scanned and a selection vector narrows the candidate rows; the selection is applied to filter columns and used to fetch remaining columns (`src/storage/table/row_group.cpp:1007`–`:1052`, `:1072`–`:1091`). The output chunk's cardinality is then set to the approved count (`:1095`–`:1098`). Thus the filter is part of the scan in this plan, not a separate physical Filter node.
- `PipelineExecutor::ExecutePushInternal` runs intermediate operators then sends a nonempty chunk to the sink (`src/parallel/pipeline_executor.cpp:562`, `:583`, `:591`–`:598`). Its operator loop calls the operator with a previous and an output chunk (`:746`, `:774`–`:783`). `PhysicalProjection::Execute` delegates to `ExpressionExecutor` (`src/execution/operator/projection/physical_projection.cpp:50`–`:54`), which evaluates expressions into output vectors and sets output cardinality from its input (`src/execution/expression_executor.cpp:115`–`:124`).
- `PhysicalUngroupedAggregate::Sink` sends each incoming projected chunk into local aggregation state (`src/execution/operator/aggregate/physical_ungrouped_aggregate.cpp:376`–`:388`). The aggregate execution state evaluates its arguments and sends the payload and count to local state (`:207`–`:209`, `:230`–`:254`); the local state dispatches an aggregate update callback (`:391`–`:410`). `Combine` merges local state into global state (`:436`–`:448`). `Finalize` marks the global state finished (`:662`–`:672`). On its source side, `GetDataInternal` finalizes into a one-row output chunk (`:715`–`:736`). That chunk is then available to the downstream result pipeline; this inspection does not establish the particular client materialization path.

## Verified: pushed-down filtering

### Manual observation and independent LLDB reproduction

The student reported that `approved_tuple_count` changed from 2,048 to 1,638 at `row_group.cpp:1051`–`:1053` and that qualifying positions were inspected with `sel.get_index()`. The student's exact selected indices were not provided.

In a separate reproduction using the same debug build and database, LLDB stopped at line 1051 with `max_count = 2048`, `count = 2048`, and `approved_tuple_count = 2048`. It then stopped at line 1055, after the filter loop, in the same thread and scan state; `approved_tuple_count` was **1638**. The first eight selection entries, read with `sel.get_index(0)` through `sel.get_index(7)`, were **1, 2, 3, 4, 6, 7, 8, 9**. These are positions within the scanned vector; no original manual index values were supplied for comparison. The query returned `126989.25` and exited successfully. Actual debugger commands and output, including the failed stepping attempts, are in `evidence/filter-trace.txt`.

The first two attempts did not yet pass the multi-line call: LLDB stopped at line 1052 and then back at line 1051 while preparing its arguments, so the count remained 2048 and the displayed indices were the pre-filter selection. The third attempt used a breakpoint at line 1055 to inspect the state after the filter loop. It reproduces the student's reported count change; it does not show which internal filter implementation executed.

After filtering, if no positions remain, the scan resets the result and skips the remaining columns (`src/storage/table/row_group.cpp:1055`–`:1070`). Otherwise, it slices the returned filter-column vectors using `sel` and `approved_tuple_count` (`:1072`–`:1079`), passes the same selection and count to `Select` for other columns (`:1081`–`:1091`), and sets the output chunk's child cardinality to the approved count (`:1095`–`:1098`). These later steps are source-verified; the filter reproduction did not separately stop at each one.

The physical scan initializes its table function with filter information (`src/execution/operator/scan/physical_table_scan.cpp:39`–`:48`); `DuckTableScanState::InitializeScanInfo` retains `input.filters` and initializes scan state with them (`src/function/table/table_scan.cpp:418`–`:435`). The planner passes `table_filters` into `PhysicalTableScan` (`src/execution/physical_plan/plan_get.cpp:243`–`:246`).

`RowGroup::PrepareScan` can use zonemaps to skip segments and obtains visibility information (`src/storage/table/row_group.cpp:912`, `:957`–`:962`). In the filtered path, `RowGroup::ProcessPreparedScan` calls the relevant column's `Filter` with `sel` and `approved_tuple_count` (`:1027`–`:1052`). The base `ColumnData::Filter` scans the column and calls `ColumnSegment::FilterSelection` (`src/storage/table/column_data.cpp:421`–`:427`); particular column/compression implementations can take alternative paths. `ColumnSegment::FilterSelection` chooses a fast expression-filter executor when available and eligible, otherwise the general expression path (`src/storage/table/column_segment.cpp:506`–`:514`).

The fast comparison executor normalizes the vector and updates the selection and approved count (`src/planner/table_filter_state.cpp:350`–`:381`); its `COMPARE_GREATERTHANOREQUALTO` case selects `GreaterThanEquals` (`:425`–`:435`). This is an available implementation for an eligible comparison; the actual callback and branch taken by this query require runtime confirmation. The scan may also use statistics to skip work or label a filter always true (`src/storage/table/row_group.cpp:763`–`:788`).

## Verified: scheduling and pipeline boundary

`Pipeline::Schedule` selects parallel scheduling or a sequential task (`src/parallel/pipeline.cpp:361`–`:372`); `PipelineTask::ExecuteTask` creates a `PipelineExecutor` and calls its `Execute` (`:52`–`:71`). The executor's chunk loop and operator dispatch are in `src/parallel/pipeline_executor.cpp:331`, `:383`–`:415`, `:562`–`:598`, and `:746`–`:783`. `PushFinalize` calls the sink's `Combine` (`:689`–`:704`).

The aggregate declares itself both source and sink (`src/include/duckdb/execution/operator/aggregate/physical_ungrouped_aggregate.hpp:37`–`:60`). Generic `PhysicalOperator::BuildPipelines` makes a sink the source of the current pipeline and builds a child meta-pipeline for its input (`src/execution/physical_operator.cpp:245`, `:259`–`:268`). This is the source-level pipeline boundary: the input pipeline accumulates aggregate state; the downstream pipeline reads the finalized aggregate output.

## Remaining assumptions to verify at runtime

- The reproduction reached the row-group filter loop for one scan vector. It did not determine whether the fast executor, fallback, compression-specific path, or zonemap simplification executes for each scan unit.
- One selected chunk was observed at scan, projection, and aggregate sink, followed by a one-row aggregate output. The complete number of calls, all chunk sizes and values, and local/global combine state remain unverified. Do not infer chunk counts from the plan's estimates or the default vector size.
- The arithmetic expression and `sum_no_overflow` shown in `EXPLAIN` identify plan expressions; the actual scalar and aggregate update callbacks still need inspection.

## Suggested LLDB session and breakpoints

From the `duckdb-research` directory, start your session with:

```sh
lldb -- ../duckdb/build/debug/duckdb -no-agent -readonly dataset/cafe-10k.duckdb -c 'SELECT SUM(quantity * unit_price) AS revenue FROM cafe_sales WHERE quantity >= 2;'
```

Set the following at the LLDB prompt. Full relative paths are relative to `../duckdb`; use absolute paths if LLDB does not resolve a source file. The ordered reproduction above used a subset of these locations; the preliminary attempt did not capture the intended variables at the broader set.

| Breakpoint | Inspect | What it can establish |
|---|---|---|
| `breakpoint set --file src/execution/physical_operator.cpp --line 259` | `this`, `current`, `children`; identify operator type | Whether the aggregate reaches the sink branch while constructing pipelines. This location can also stop for other operators. |
| `breakpoint set --file src/parallel/pipeline_executor.cpp --line 415` | `source_chunk`, `source_chunk.size()`, `source_result.result` | Chunk returned by the source before pushing it through intermediate operators. |
| `breakpoint set --file src/execution/operator/scan/physical_table_scan.cpp --line 186` | `function`, `data`, `chunk`; step over callback to inspect `chunk.size()` | Which table-function callback handles the scan and what it returns. |
| `breakpoint set --file src/storage/table/row_group.cpp --line 1051` | `max_count`, `count`, `approved_tuple_count`, `filter`, `sel`; step over call and compare `approved_tuple_count` | The scan-side filter and selected row count, if this path executes. |
| `breakpoint set --file src/storage/table/column_segment.cpp --line 509` | `state.fast_executor`, `scan_count`, `approved_tuple_count`, `vector` | Whether the generic filter dispatcher chooses the fast executor or fallback, if this dispatcher is reached. |
| `breakpoint set --file src/execution/operator/projection/physical_projection.cpp --line 53` | `input.size()`, `input.data`; step over and inspect `chunk.size()`, `chunk.data` | Input/output cardinality and computed projection vectors. |
| `breakpoint set --file src/execution/operator/aggregate/physical_ungrouped_aggregate.cpp --line 387` | `chunk.size()`, `chunk.data`, `sink.state` before/after | Chunk received by the aggregate and its local state update. |
| `breakpoint set --file src/execution/operator/aggregate/physical_ungrouped_aggregate.cpp --line 448` | `lstate.state`, `gstate.state` before/after | Local-to-global combine. |
| `breakpoint set --file src/execution/operator/aggregate/physical_ungrouped_aggregate.cpp --line 732` | `gstate.finished`; step over, then inspect `chunk.size()` and `chunk.GetValue(0, 0)` | Final aggregate output chunk. |

`DataChunk::size()` and `GetValue` are C++ calls; LLDB expression evaluation may require emitted symbols and can fail. If so, inspect fields with `frame variable`, or step to where the source computes or prints the value. Variables declared later on a line are not available before execution reaches their declaration. Some source-line breakpoints may resolve to multiple locations or not be hit because the optimizer, storage encoding, scheduling, or execution branch differs.

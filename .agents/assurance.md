# Assurance

How this package meets the shared `assurance.md` rules. CI checks this
file (r-actions `assurance.yml`), so keep the headings and table
columns as they are.

- **Statuses:** a cell is a fact, `gap #<issue>` or `n/a: <reason>`.
- **Started:** 2026-11-26, Stage 0, before any code. Every row below is
  planned; the stage named in each gap's issue fills it, and
  [Stage 8](roadmap.md#stage-8--assurance) checks none is left.

## Kinds

`untrusted-input` `spec`

## Required checks

`Where` names the workflow file under `.github/workflows/` that runs the
check. Add `(own)` when that workflow is the package's own rather than a
call to r-actions.

<!-- markdownlint-disable MD013 -->
| Check      | Status                                                                                                                                  | Where |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| fuzz       | n/a: pure R; r-actions fuzz.yml fuzzes C through libFuzzer, and the hostile-log tests and filter property test carry the oracle | |
| fuzz-reach | n/a: pure R; r-actions fuzz.yml fuzzes C through libFuzzer, and the hostile-log tests and filter property test carry the oracle | |
<!-- markdownlint-enable MD013 -->

## Boundaries

One row per boundary the package crosses. An oracle knows the answer:

- a conformance suite or test vectors;
- a reference implementation;
- a round trip;
- equivalent inputs compared;
- the bytes the other side received.

"No crash" is not an oracle. The reference implementation is `deltalake`
1.7.0, whose answers Stage 1 commits under
`tests/testthat/fixtures/answers/` and `oracle.yaml` (own) regenerates and
diffs; `expect_oracle()` in `tests/testthat/helper-oracle.R` compares
against them (its own tests: `tests/testthat/test-fixtures.R`).

<!-- markdownlint-disable MD013 -->
| Boundary                                                                                          | Oracle                                                                                                       | Carried by |
| ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ---------- |
| Delta commit log (`_delta_log/` listing, `_last_checkpoint`, JSON commits, log compaction files) | `deltalake` live add actions, protocol and transactions at every version of every fixture, and its `load_as_version()` timestamp answers; the `_delta_log/` directory listing; replay with and without the compaction file; hostile logs refused with a classed `zulake_error` | `tests/testthat/test-replay.R`, `tests/testthat/test-hostile.R` |
| Checkpoints (classic, multi-part, V2 with sidecars) | replay from the checkpoint equals replay from commit 0, and both equal `deltalake`; Stage 2b ([#26](https://github.com/pedrobtz/zulake/issues/26)) | gap #16 |
| Reader-feature gate (`protocol.readerFeatures`) | the protocol's appendix of feature names: each unsupported one refused by name before any file outside `_delta_log/` is read (a recording storage backend); `deltalake`'s own refusals of `catalogManaged` and an unknown feature, and its opening of `vacuumProtocolCheck`; writer-only features never refuse | `tests/testthat/test-protocol.R` |
| Inspection (the log's actions, statistics JSON and partition values as data frames) | `deltalake`'s add actions, statistics, partitions, count, history, schema, protocol, metadata and transactions at every version of every fixture; the oracle's own parse of each commit (`lake_actions()`, tombstones, domains); the `_delta_log/` directory (`lake_log()`, `lake_checkpoints()`); R's evaluation of random partition filters on `deltalake`'s partition values | `tests/testthat/test-inspect.R`, `tests/testthat/test-filter.R`, `tests/testthat/test-types.R` |
| Data reading (Parquet data files through `qio`, partition columns added, columns `qio` cannot return, `lake_count(footers = TRUE)`) | `deltalake`'s full table read of every fixture version without deletion vectors or column mapping (qio's documented losses applied, design section 8), and in `int64 = "integer64"`; `lake_walk()` pieces bound equal to `lake_read()`; footer row counts equal to `deltalake`'s read row count on the fixtures without statistics; the nested columns of `zl-types` named by `zulake_warning_column_skipped`, or `zulake_error_column_unreadable` when asked for, found from `qio::read_plan()` (a schema that hides them); downloads through a backend without local paths, one per file per session, and a short download refused; deletion-vector and column-mapping tables refused before any data file is read (a recording storage backend) | `tests/testthat/test-read.R` |
| Pruning (partition values by Delta type, statistics, UTF-8 byte order, truncated maxima, exact comparator) | `lake_read(filter = f)` equal to the full read subset in R (C collation) for seeded random filters over ten fixtures, and every file pruning drops read whole and found to hold no matching row; `deltalake`'s partition values of every fixture, each selected exactly; hand-built statistics for byte order under two collations, a truncated maximum (and a fixture copy whose maximum was cut short still returning the row), decimal statistics past the scale or precision 15, 64-bit bounds and partition values at 2^63 - 1 and -2^63, float, timestamp and NaN widening, null counts; the exact comparator against a second implementation on random decimal text and the documented literal rules, the same in a hostile session | `tests/testthat/test-filter.R`, `tests/testthat/test-types.R` |
| Deletion vectors (descriptor, file format, CRC-32, `zuroar` bitmap)                               | `deltalake` `deletion_vectors()` row indexes, and its reads of every deletion-vector fixture                 | gap #19    |
| Z85 inline deletion vectors                                                                       | the ZeroMQ RFC 32 test vector; round trip through an independent encoder in the test                         | gap #19    |
| Column mapping (`name` mode) and `timestampNtz`                                                   | `deltalake`'s reads of the fixtures                                                                          | gap #19    |
| Azure Blob REST (`List Blobs` with prefix and marker, `Get Blob` with `Range`, `x-ms-version`)    | the bytes `zuhttp`'s cassette transport received; the live suite against `deltalake` on the same table       | gap #20    |
<!-- markdownlint-enable MD013 -->

## Limits

One row per limit the package enforces. "Straddled by" is the test of
`limit - 1`, `limit` and `limit + 1` on every path that reaches it.

<!-- markdownlint-disable MD013 -->
| Limit                                                                                  | Unit          | Straddled by |
| -------------------------------------------------------------------------------------- | ------------- | ------------ |
| 64-bit values returned as double exact up to 2^53 - 1 (D10; `int64 = "integer64"` beyond, to 2^63 - 1): sizes, `numRecords`, `nullCount`, long partition values, `txn` versions, deletion vector cardinalities, sums in `lake_summary()` and `lake_count()`, and numbers inside actions and `commitInfo` | integer value | `tests/testthat/test-types.R` ("a long statistic the int64 mode cannot hold is NA, with one classed warning per column", for long statistics, NA instead of an error since Stage 4; "every 64-bit value from the log straddles 2^53: exact, then an error, or exact as integer64"; "a sum of counts straddles 2^53 too"; "integer64 holds -2^63 + 1 to 2^63 - 1; past that, and at bit64's NA, a classed error") |
| Log versions as doubles, exact up to 2^53 - 1 (design section 7): a log file name or `version` argument at 2^53 or more is refused | version | `tests/testthat/test-replay.R` ("log versions are exact up to 2^53 - 1 and refused from 2^53") |
| Decimal precision a double holds exactly: 15 (design section 7); a `decimal(p, s)` column with p <= 15 is a double, wider is a column `qio` cannot return, and a wider decimal statistic is never a bound | digits of precision | `tests/testthat/test-read.R` ("decimal precision straddles 15 in reads and in statistics") |
<!-- markdownlint-enable MD013 -->

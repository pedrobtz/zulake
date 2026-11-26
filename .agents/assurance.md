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
| Delta commit log (`_delta_log/` listing, `_last_checkpoint`, JSON commits)                        | `deltalake` live add actions at every version of every fixture; the `_delta_log/` directory listing          | gap #16    |
| Checkpoints (classic, multi-part, V2 with sidecars, compaction files)                             | replay from the checkpoint equals replay from commit 0, and both equal `deltalake`                           | gap #16    |
| Reader-feature gate (`protocol.readerFeatures`)                                                   | the protocol's appendix of feature names: each unsupported one refused by name before any data file is read | gap #16    |
| Data reading (Parquet data files through `qio`, partition columns added)                          | `deltalake`'s full table read of every fixture                                                               | gap #18    |
| Pruning (partition values by Delta type, statistics, UTF-8 byte order, truncated maxima)          | the full read subset in R, for random filters; `deltalake`'s partition values                                | gap #18    |
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
| 64-bit values returned as double exact up to 2^53 (D10; `int64 = "integer64"` beyond) | integer value | gap #17      |
<!-- markdownlint-enable MD013 -->

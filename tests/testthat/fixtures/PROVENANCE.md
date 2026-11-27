# Fixture provenance

The Delta tables zulake's tests read, where each came from, what wrote it,
and what it is there to exercise. The tables and the hostile logs ship packed
in `delta-fixtures.tar`, because their paths are longer than a package
tarball allows; the unpacked trees `tables/` and `hostile/` are in the git
repository only. `answers/` holds `deltalake` 1.7.0's answers for every table
at every version (`tools/oracle/README.md`), and `hostile-answers.json`
whether it refuses each hostile log, and why.

## Licences

- **From delta-rs** (Apache-2.0, `LICENSE-delta-rs.txt` here, the root
  `LICENSE.txt` of [delta-io/delta-rs](https://github.com/delta-io/delta-rs)):
  copied byte for byte from `crates/test/tests/data/` at commit
  `40439ad6d37a9e99add5bd80796aa6179ebe339f` (main on 2026-11-26) by
  `tools/fixtures/fetch-delta-rs.sh`. `COVID-19_NYT`, New York Times data
  under its own terms, is not copied.
- **Changed from delta-rs** (Apache-2.0, with the change stated below as its
  section 4(b) asks): made by `tools/fixtures/generate.py` from a copied
  table.
- **zulake's own** (MIT, the package licence): the `zl-*` tables, written by
  `deltalake` 1.7.0's writer through `tools/fixtures/generate.py`, with the
  log edits stated below.
- **Hostile logs**: made by `tools/fixtures/hostile.R` from the tables
  above (and `checkpoint-map-repeated-key` by
  `tools/fixtures/hostile_parquet.py`, which needs a Parquet writer), each
  under its source table's licence.

DAT (`delta-incubator/dat`) is not used: it has no licence (design §12, Q3).

## Tables

<!-- markdownlint-disable MD013 -->
| Table | Source | Writer | Versions | Covers |
| --- | --- | --- | --- | --- |
| `checkpoint-v2-table` | delta-rs | Databricks Runtime 17.0 | 0–9 | V2 checkpoints named by UUID (JSON) with Parquet sidecars, `_last_checkpoint` carrying `v2Checkpoint`, `.crc` version files |
| `column_mapping` | delta-rs | Spark 3.5.1, Delta 3.1.0 | 0–3 | `columnMapping` in `name` mode, a column renamed at version 2 |
| `deletion_vectors` | delta-rs | Spark 3.5.1, Delta 3.1.0 | 0–2 | on-disk deletion vector; a file re-added with a new vector (the `(path, deletionVector.uniqueId)` key) |
| `delta-0.8.0-null-partition` | delta-rs | Delta 0.8.0 | 0 | a null partition value |
| `delta-0.8.0-partitioned` | delta-rs | Delta 0.8.0 | 0 | three partition columns, Hive-style directories, Hadoop `.crc` sidecars |
| `delta-2.2.0-partitioned-types` | delta-rs | Spark 3.3.1, Delta 2.2.0 | 0 | partition values of several types |
| `simple_table` | delta-rs | Spark (Delta 0.x) | 0–4 | removes (tombstones), commits without statistics, an uncommitted version 5 left in `_delta_log/.tmp/` that readers must ignore |
| `simple_table_with_checkpoint` | delta-rs | Spark (Delta 0.x) | 0–10 | classic single-part checkpoint at 10 with `_last_checkpoint` |
| `table-with-dv-small` | delta-rs | Databricks Runtime | 0–1 | on-disk deletion vector (`storageType` `u`), the source of the deletion-vector hostile logs |
| `table_failed_last_checkpoint_update` | delta-rs | delta-rs 0.17.1 | 0–3 | `_last_checkpoint` stale: it names version 1 while a checkpoint at 3 exists |
| `table_with_column_mapping` | delta-rs | Databricks Runtime 13.3 | 0 | `name`-mode column mapping with a partition column whose name has spaces, random file prefixes |
| `table_with_edge_timestamps` | delta-rs | Spark | 0 | timestamps at 9999-12-30 and 9999-12-31, past the nanosecond range |
| `table_with_ict` | delta-rs | Spark 4.2.0, Delta 4.4.1 | 0–3 | `inCommitTimestamp` |
| `v2-classic-checkpoint-json` | delta-rs | Spark 3.5.3, Delta 3.4.0 | 0–1 | V2 checkpoint under the classic name with a sidecar; data file names with `%` |
| `column_mapping_id_mode` | changed from delta-rs `column_mapping` | Spark 3.5.1; changed by `generate.py` | 0–3 | `columnMapping` in `id` mode, which zulake refuses (D7) and `deltalake` reads. Change: `delta.columnMapping.mode` set to `"id"` in the `metaData` of commits 0 and 2, each commit re-serialised |
| `table-with-dv-small-inline` | changed from delta-rs `table-with-dv-small` | Databricks Runtime; changed by `generate.py` | 0–1 | an inline (Z85, `storageType` `i`) deletion vector. Change: commit 1's descriptor replaced by the inline encoding of the same bitmap, the `.bin` file removed, commit 1 re-serialised |
| `zl-basic` | zulake | `deltalake` 1.7.0 | 0–4 | appends, a delete (file rewritten), an overwrite, `txn` for two applications, custom commit metadata |
| `zl-catalog-managed` | zulake | `deltalake` 1.7.0; edited | 0–1 | commit 1 (by hand) upgrades the protocol to reader feature `catalogManaged`, with `inCommitTimestamp` enabled from version 1 and a `txnId`, as the protocol requires; zulake must refuse version 1 by that name, and `deltalake` refuses it (no catalog) |
| `zl-checkpoint` | zulake | `deltalake` 1.7.0 | 0–12 | classic checkpoints at 5 and 10, removes before each, commits after the last |
| `zl-checkpoint-no-last` | zulake | `deltalake` 1.7.0; edited | 0–3 | a checkpoint at 2 and no `_last_checkpoint` (deleted after writing) |
| `zl-dotted-name` | zulake | `deltalake` 1.7.0 | 0 | a top-level column `a.b` beside a struct `a` with a field `b`, whose paths qio cannot tell apart (pedrobtz/qio#78): zulake leaves `a.b` out by name and reads the rest (added 2026-11-27, #116) |
| `zl-domains` | zulake | `deltalake` 1.7.0; edited | 0–4 | `domainMetadata` added, changed and removed, in commits 1–3 written by hand with the `domainMetadata` writer feature |
| `zl-decimal-partitions` | zulake | `deltalake` 1.7.0 | 0 | `decimal(10,2)` and `decimal(4,2)` partition columns, a null among them: the source of the `decimal-partition-*` hostile logs (added 2026-11-27, #112) |
| `zl-file-times` | zulake | `deltalake` 1.7.0; edited | 0–2 | commit times that go back: each `commitInfo.timestamp` set to 2025-01-01 00:01:40, 00:00:50 and 00:03:20 UTC, so the commit files dated by them (`answers.py`) have decreasing times from 0 to 1, as a copy that drops times can leave them; `deltalake` makes them increasing before a timestamp lookup (added 2026-11-27, #52) |
| `zl-inf-partitions` | zulake | `deltalake` 1.7.0 | 0 | `double` and `float` partition columns holding infinities and NaN, which `deltalake` writes as `inf`, `-inf` and `NaN` (added 2026-11-27, #67) |
| `zl-int32-in-long` | zulake | `deltalake` 1.7.0; edited | 0–1 | a `long` column, INT64 in the file `deltalake` wrote at version 0 and INT32 in `part-int32.parquet`, written by pyarrow 22.0.0 and added by hand at version 1 with its statistics; `deltalake` upcasts it (added 2026-11-27, #119) |
| `zl-int32-min` | zulake | `deltalake` 1.7.0 | 0 | an `int32` column holding -2^31 and no null (`nullCount` 0), which qio reads as `NA`: `is.na()` must not be pruned on the null count (added 2026-11-27, #79) |
| `zl-int64-edges` | zulake | `deltalake` 1.7.0 | 0–5 | a `long` column at ±(2^53 - 1), ±2^53, -2^63, 2^63 - 1 and 2^53 + 1, one append per file and no null (`nullCount` 0): qio reads the values past 2^53 as `NA` with `int64 = "double"` and -2^63 as bit64's `NA` with `"integer64"`, so `is.na()` must not be pruned on the null count (added 2026-11-27, #111) |
| `zl-log-compaction` | zulake | `deltalake` 1.7.0 | 0–5 | a log compaction file for commits 1 to 3 (`compact_logs()`) |
| `zl-multipart-checkpoint` | zulake | `deltalake` 1.7.0; edited | 0–5 | a three-part checkpoint at 4: the single-part checkpoint `deltalake` wrote, split into three Parquet files by row, `_last_checkpoint` with `parts = 3` |
| `zl-orders` | zulake | `deltalake` 1.7.0; edited | 0–4 | the example table the package ships, copied to `inst/extdata/orders/` by `pack.py`: orders partitioned by `region` (`long`, `string`, `double`, `date`), created, appended twice, a row delete that rewrites one file, and an append with an application transaction and custom commit metadata (added 2026-11-26, Stage 7). Edits, so that every build is the same bytes: data files renamed `region=<r>/part-<n>.parquet` (by version, then region) and every `add` and `remove` path rewritten to match; `inCommitTimestamp` enabled from version 0 (protocol replaced by reader 1, writer 7, writer feature `inCommitTimestamp`; `delta.enableInCommitTimestamps` in `metaData`), each `commitInfo` given `inCommitTimestamp` and `timestamp` of 09:00 UTC on 2025-01-06 to 2025-01-10 and moved first; `modificationTime`, `deletionTimestamp`, `txn.lastUpdated` and `createdTime` set to those times, the table id and `txnId`s fixed, timing metrics zeroed, statistics and `commitInfo` keys sorted, actions in a fixed order |
| `zl-partition-types` | zulake | `deltalake` 1.7.0; edited | 0–1 | every type that can be a partition (`byte`, `short`, `integer`, `long`, `float`, `double`, `decimal(10,2)`, `string`, `boolean`, `date`, `timestamp`, `timestamp_ntz`, `binary`) twice, as a partition column `p_<type>` and a data column `d_<type>` with the same values, at their edges (-2^31, the largest float, -0, 1969-12-31T23:59:59.999999), one file per row with a null row (added 2026-11-27, #118). Edits: data files renamed `part-<id>.parquet` at the root and their `add` paths rewritten; each `p_binary` value, which `deltalake` writes as the literal text of its escapes (`\u0061...`) and reads back as those bytes, replaced by the UTF-8 text of its `d_binary` bytes; version 1 by hand: two files written by pyarrow 22.0.0 whose partition texts are `16777217` and `1e39` for `p_float` and `2024-01-05 10:00:00.123456789` and `2024-01-05T10:00:00.999999999Z` for `p_timestamp`, with `d_float` and `d_timestamp` holding what `deltalake` reads (16777216, `Inf`, the microsecond) |
| `zl-partitioned` | zulake | `deltalake` 1.7.0 | 0–2 | string, integer and date partition columns; nulls, spaces, `/`, `=`, `%` and non-ASCII in values; a partition deleted |
| `zl-types` | zulake | `deltalake` 1.7.0 | 0 | every type the writer has, at its edges: 8 to 64-bit integers at their limits and at 2^53 ± 1, signed zero and infinities, decimals of precision 10 and 38, non-ASCII strings, binary, dates of years 1 and 9999, `timestamp` and `timestamp_ntz`, struct, list and map |
| `zl-void` | zulake | `deltalake` 1.7.0; edited | 0 | a `void` column, at the top level (`v`) and inside the struct `st` (`nv`), added to commit 0's schema by hand; no data file holds either, as PROTOCOL.md has void columns (added 2026-11-27, #133) |
| `zl-unknown-reader-feature` | zulake | `deltalake` 1.7.0; edited | 0–1 | commit 1 (by hand) upgrades the protocol to reader feature `zulakeUnknownFeature`; every reader must refuse version 1 by that name |
| `zl-vacuum-protocol-check` | zulake | `deltalake` 1.7.0; edited | 0–2 | commit 1 (by hand) upgrades the protocol to reader and writer feature `vacuumProtocolCheck`, then `deltalake` appends at version 2; readers only acknowledge the feature, so zulake and `deltalake` both open every version (added 2026-11-26, Stage 3, design D7 amendment) |

## Hostile logs

| Log | From | Change |
| --- | --- | --- |
| `add-then-remove-same-file` | `zl-basic` | commit 2 ends with a `remove` of the file its `add` (line 2) adds, which the protocol forbids in one commit (#103) |
| `checkpoint-map-repeated-key` | `zl-checkpoint-no-last` | the checkpoint at 2, rewritten by pyarrow 22.0.0 (`hostile_parquet.py`, uncompressed): its first `add` has the `partitionValues` MAP `[x: 1, x: 2]`, a key twice (#108). The one hostile log that opens: the checkpoint is passed over for the commits, and is unreadable once commit 0 is gone |
| `column-mapping-duplicate-physical-name` | `column_mapping` | field `int` given `letter`'s `delta.columnMapping.physicalName` in commit 0's schema; commit 2's schema has its own (#120) |
| `column-mapping-no-physical-name` | `column_mapping` | the `delta.columnMapping.physicalName` of field `letter` removed from commit 0's schema; commit 2's schema has it (#77) |
| `corrupt-commit` | `zl-basic` | line 2 of commit 2 is not JSON |
| `data-type-long-for-integer` | `zl-basic` | field `id` (INT64 in every data file) typed `integer` in commit 0's schema; `deltalake` reads it, the values fitting, and zulake refuses it (#119) |
| `data-type-string-for-long` | `zl-types` | field `s` (strings in its one data file, so that `deltalake`'s refusal names one value) typed `long` in commit 0's schema (#119) |
| `decimal-partition-exponent` | `zl-decimal-partitions` | the `pdec` partition value `12.30` in commit 0 written `1e2` (#112) |
| `decimal-partition-negative-no-integer-digit` | `zl-decimal-partitions` | the `pdec` partition value `12.30` in commit 0 written `-.5` (#112) |
| `decimal-partition-no-fraction-digit` | `zl-decimal-partitions` | the `pdec` partition value `12.30` in commit 0 written `5.` (#112) |
| `decimal-partition-no-integer-digit` | `zl-decimal-partitions` | the `pdec` partition value `12.30` in commit 0 written `.5` (#112) |
| `decimal-partition-past-precision` | `zl-decimal-partitions` | the `pdec` partition value `12.30` in commit 0 written `123456789.00`, nine integer digits in a `decimal(10,2)` (#112) |
| `decimal-partition-past-precision-small` | `zl-decimal-partitions` | the `pd4` partition value `12.34` in commit 0 written `123.45`, three integer digits in a `decimal(4,2)` (#112) |
| `decimal-partition-past-scale` | `zl-decimal-partitions` | the `pdec` partition value `12.30` in commit 0 written `12.345`, three fraction digits in a `decimal(10,2)` (#112) |
| `duplicate-action-key` | `zl-basic` | line 3 of commit 2 holds a second `remove` key, removing the file commit 1 added (#102) |
| `duplicate-key-in-add` | `zl-basic` | the `add` on line 2 of commit 2 has a second `path` key, naming the file line 3 removes (#102) |
| `dv-bad-checksum` | `table-with-dv-small` | the deletion vector file's last byte (its CRC-32) flipped |
| `dv-bad-magic` | `table-with-dv-small` | the deletion vector's magic number (file bytes 6 to 9) zeroed |
| `dv-size-past-file` | `table-with-dv-small` | the descriptor's `sizeInBytes` 4096, past the end of its 45-byte file |
| `last-checkpoint-past-log` | `zl-checkpoint` | `_last_checkpoint` names version 99; the log ends at 12 |
| `missing-checkpoint-part` | `zl-multipart-checkpoint` | part 2 of the three-part checkpoint deleted |
| `partition-value-wrong-type` | `zl-partitioned` | an integer partition value `"one"` in commit 1 |
| `remove-then-add-same-file` | `zl-basic` | commit 2 has a `remove` of the file its `add` adds, on the line before it (#103) |
| `schema-duplicate-name` | `zl-basic` | field `x` of commit 0's schema renamed `label`, so two fields are named `label` (#120) |
| `schema-duplicate-name-case` | `zl-basic` | field `x` of commit 0's schema renamed `LABEL`, beside `label` (#134) |
| `schema-duplicate-name-case-nested` | `zl-basic` | field `x` of commit 0's schema typed as a struct of two `long` fields `a` and `A` (#134) |
| `schema-empty-name` | `zl-basic` | field `x` of commit 0's schema renamed `""` (#120) |
| `schema-field-without-name` | `zl-basic` | the `name` of field `x` removed from commit 0's schema (#120) |
| `schema-field-without-type` | `zl-basic` | the `type` of field `label` removed from commit 0's schema (#120) |
| `schema-repeated-key` | `zl-basic` | the `schemaString` of commit 0 gives field `id` a second `type` key, `"string"` before `"long"` (#107) |
| `schema-timestamp-ntz-without-feature` | `zl-basic` | field `label` of commit 0's schema typed `timestamp_ntz`; the protocol (reader 1) has no `timestampNtz` (#120) |
| `schema-unknown-type` | `zl-basic` | field `label` of commit 0's schema typed `varchar(10)` (#120) |
| `schema-upper-case-type` | `zl-basic` | field `label` of commit 0's schema typed `STRING` (#120) |
| `schema-variant-without-feature` | `zl-basic` | field `label` of commit 0's schema typed `variant`; the protocol (reader 1) has no `variantType` (#120) |
| `stats-repeated-column` | `zl-basic` | the statistics of commit 4's `add` hold `id` twice in `minValues`, 13 before 12 (#107) |
| `stats-repeated-key` | `zl-basic` | the statistics of commit 4's `add` hold `maxValues` twice, `{"id":11}` before the writer's (#107) |
| `truncated-commit` | `zl-basic` | commit 4 cut to its first half, mid-line |
| `two-actions-one-line` | `zl-basic` | commit 2's `add` (line 2) and `remove` (line 3) joined into one line, `{"add":{...},"remove":{...}}` (#121) |
| `two-adds-same-file` | `zl-basic` | commit 2's `add` (line 2) repeated on line 3 with `minValues.id` 0 instead of 1 (#106) |
| `two-adds-same-path-new-dv` | `table-with-dv-small` | commit 1 ends with a second `add` of its file, with `table-with-dv-small-inline`'s inline deletion vector (#106) |
| `two-removes-same-file` | `zl-basic` | commit 3's `remove` of `part-...e10fff6f...` repeated on the next line, with `deletionTimestamp` one millisecond later (#106) |
<!-- markdownlint-enable MD013 -->

## Regenerating

From the package root, in this order (each step's output is committed):

```sh
sh tools/fixtures/fetch-delta-rs.sh                       # delta-rs tables
(cd tools/oracle && uv run --frozen python ../fixtures/generate.py)   # zl-* and changed tables
Rscript tools/fixtures/hostile.R                          # hostile logs
(cd tools/oracle && uv run --frozen python ../fixtures/hostile_parquet.py) # the Parquet one
(cd tools/oracle && uv run --frozen python ../fixtures/pack.py)       # delta-fixtures.tar
(cd tools/oracle && uv run --frozen python answers.py)    # answers/, hostile-answers.json
```

`generate.py` names files by random UUID and stamps commits with the clock,
so rerunning it changes the `zl-*` tables and every answer for them; run it
only to change a table. `zl-orders` is the exception: its build is
deterministic, and `oracle.yaml` rebuilds it with `generate.py orders`. The last four steps are deterministic, and
`.github/workflows/oracle.yaml` reruns them and fails on any difference.

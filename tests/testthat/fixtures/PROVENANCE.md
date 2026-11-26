# Fixture provenance

The Delta tables zulake's tests read, where each came from, what wrote it,
and what it is there to exercise. The tables and the hostile logs ship packed
in `delta-fixtures.tar`, because their paths are longer than a package
tarball allows; the unpacked trees `tables/` and `hostile/` are in the git
repository only. `answers/` holds `deltalake` 1.7.0's answers for every table
at every version (`tools/oracle/README.md`).

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
  above, each under its source table's licence.

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
| `zl-domains` | zulake | `deltalake` 1.7.0; edited | 0–4 | `domainMetadata` added, changed and removed, in commits 1–3 written by hand with the `domainMetadata` writer feature |
| `zl-log-compaction` | zulake | `deltalake` 1.7.0 | 0–5 | a log compaction file for commits 1 to 3 (`compact_logs()`) |
| `zl-multipart-checkpoint` | zulake | `deltalake` 1.7.0; edited | 0–5 | a three-part checkpoint at 4: the single-part checkpoint `deltalake` wrote, split into three Parquet files by row, `_last_checkpoint` with `parts = 3` |
| `zl-partitioned` | zulake | `deltalake` 1.7.0 | 0–2 | string, integer and date partition columns; nulls, spaces, `/`, `=`, `%` and non-ASCII in values; a partition deleted |
| `zl-types` | zulake | `deltalake` 1.7.0 | 0 | every type the writer has, at its edges: 8 to 64-bit integers at their limits and at 2^53 ± 1, signed zero and infinities, decimals of precision 10 and 38, non-ASCII strings, binary, dates of years 1 and 9999, `timestamp` and `timestamp_ntz`, struct, list and map |
| `zl-unknown-reader-feature` | zulake | `deltalake` 1.7.0; edited | 0–1 | commit 1 (by hand) upgrades the protocol to reader feature `zulakeUnknownFeature`; every reader must refuse version 1 by that name |
| `zl-vacuum-protocol-check` | zulake | `deltalake` 1.7.0; edited | 0–2 | commit 1 (by hand) upgrades the protocol to reader and writer feature `vacuumProtocolCheck`, then `deltalake` appends at version 2; readers only acknowledge the feature, so zulake and `deltalake` both open every version (added 2026-11-26, Stage 3, design D7 amendment) |

## Hostile logs

| Log | From | Change |
| --- | --- | --- |
| `corrupt-commit` | `zl-basic` | line 2 of commit 2 is not JSON |
| `dv-bad-checksum` | `table-with-dv-small` | the deletion vector file's last byte (its CRC-32) flipped |
| `dv-bad-magic` | `table-with-dv-small` | the deletion vector's magic number (file bytes 6 to 9) zeroed |
| `dv-size-past-file` | `table-with-dv-small` | the descriptor's `sizeInBytes` 4096, past the end of its 45-byte file |
| `last-checkpoint-past-log` | `zl-checkpoint` | `_last_checkpoint` names version 99; the log ends at 12 |
| `missing-checkpoint-part` | `zl-multipart-checkpoint` | part 2 of the three-part checkpoint deleted |
| `partition-value-wrong-type` | `zl-partitioned` | an integer partition value `"one"` in commit 1 |
| `truncated-commit` | `zl-basic` | commit 4 cut to its first half, mid-line |
<!-- markdownlint-enable MD013 -->

## Regenerating

From the package root, in this order (each step's output is committed):

```sh
sh tools/fixtures/fetch-delta-rs.sh                       # delta-rs tables
(cd tools/oracle && uv run --frozen python ../fixtures/generate.py)   # zl-* and changed tables
Rscript tools/fixtures/hostile.R                          # hostile logs
(cd tools/oracle && uv run --frozen python ../fixtures/pack.py)       # delta-fixtures.tar
(cd tools/oracle && uv run --frozen python answers.py)    # answers/
```

`generate.py` names files by random UUID and stamps commits with the clock,
so rerunning it changes the `zl-*` tables and every answer for them; run it
only to change a table. The last three steps are deterministic, and
`.github/workflows/oracle.yaml` reruns them and fails on any difference.

# RFC 0081: `zulake`, Delta Lake tables inspected and read from R

Adopted from [RFC 0081](https://github.com/pedrobtz/packages/blob/6a120b1d0a55f715841caec77ef44eade7ca54c3/rfcs/not-started/0081-zulake-delta-lake-tables-on-azure.md) on 2026-11-26. This file is the single source of truth for the design; the RFC is now a pointer here.

- **Status:** Proposed. Promotes the sketch in
  [more-candidates.md §3][sketch] on its Delta scope; the sketch there is
  replaced by a link to this RFC in the same change. Each decision in §10
  stays the maintainer's until the package repository records it, except
  those the maintainer settled on 2026-11-25 (D2 to D6, and D11).
- **Date:** 2026-11-25.
- **Packages:** `zulake` (not yet created; `crandb.r-pkg.org/zulake`
  returns `not_found` and there is no `pedrobtz/zulake` repository, both
  checked on 2026-11-25). `Imports: zujson, qio, zuhttp`.
  `Suggests: zuroar, testthat (>= 3.2.0), withr`. No compiled code and
  no vendored code: the log replay is R. MIT.
- **Source:** the Delta protocol, `PROTOCOL.md` at `delta-io/delta`
  `483d55e` (2026-11-25); the Python `deltalake` package 1.7.0
  (`delta-io/delta-rs` tag `python-v1.7.0`, released 2026-11-22),
  `python/deltalake/table.py` read for its read and inspection API; the
  default branches of `qio`, `zujson`, `zuhttp` and `zuroar` on
  2026-11-25 (`NAMESPACE`, `R/parquet.R`, `R/parquet-file.R`,
  `R/serial.R`, `.agents/design.md`); pedrobtz/zuroar#71 (bit vectors);
  the zugodb design §16 (extensions). Nothing has been built.

## 1. What zulake is

`zulake` opens a Delta Lake table where it is stored, in practice Azure
Data Lake Storage Gen2 or Blob Storage, and answers every question the
table's own log can answer: which versions exist and who wrote them,
which files make up a version, with their partition values, statistics
and deletion vectors, what the schema, protocol, features and properties
are, and what changed between two versions. Then it reads the data,
pruning files by partition and statistics before downloading any of
them, the way the Python `deltalake` package does:

```r
tbl <- lake_open(
  "abfss://lake@account.dfs.core.windows.net/sales/orders",
  credentials = function() my_token()
)
lake_history(tbl, limit = 10)
lake_files(tbl, filter = year == 2026 & region %in% c("EU", "UK"))
lake_read(tbl, columns = c("id", "amount"), filter = year == 2026)
```

> **Inspection first.** The main purpose is to look inside a table:
> every action in its log is reachable as a data frame, unchanged.
> Reading the data is the convenience on top.

### 1.1 What zulake is not

- Not a writer. No commits, `vacuum`, `optimize`, `restore` or merges.
- Not a query engine. A filter prunes files and then rows; there is no
  join, aggregation or SQL. `zugodb` (RFC 0075) or `duckdb` do that, on
  what `zulake` returns.
- Not an Azure SDK. It reads blobs and lists prefixes, nothing else, and
  obtains no token: the caller supplies one (D4).
- Not tested on S3, GCS or other stores (D3). Local paths work, because
  the tests need them.
- Not Iceberg in 0.1.0. Iceberg comes in a later version under the same
  name (D11).

### 1.2 Where it sits among CRAN packages

Nothing on CRAN reads a Delta log directly. `crandb` returned
`not_found` for `delta`, `deltalake` and `DeltaLake` on 2026-11-01
([sketch][sketch]); `delta.sharing` is a client for the Delta Sharing
protocol, not the log. R reaches Delta through engines: `duckdb` with its
`delta` extension (downloaded at run time, and opaque about the log),
`sparklyr` with a JVM, or `arrow` reading the Parquet files without the
log, which returns deleted and superseded rows. `quak` (portfolio) wraps
`duckdb`'s `delta_scan()` over ADLS. None exposes the log as data.

### 1.3 The admission test

1. **Specification.** The Delta protocol is one public document with
   versioned, named reader features; `delta-rs`'s test tables are a
   corpus (Apache-2.0; §8, Q3).
2. **Implementation.** Pure R over the protocol. No C library exists to
   vendor: `delta-rs` and `delta-kernel-rs` are Rust.
3. **Siblings.** `qio` (Parquet), `zujson` (commits), `zuhttp` (storage),
   `zuroar` (deletion vectors), and `zugodb` as the first consumer.
4. **Gap in base R.** Base R reads neither Parquet nor the log.

## 2. Scope

**In 0.1.0:**

- Tables on Azure (`abfss://`, `https://<account>.blob.core.windows.net/`
  and `https://<account>.dfs.core.windows.net/`) and on local disk.
- Snapshots at the latest version, at a version, or at a timestamp.
- Every log action as a data frame: `metaData`, `protocol`, `add`,
  `remove`, `cdc`, `txn`, `commitInfo`, `domainMetadata`, `sidecar`,
  `checkpointMetadata`.
- Classic, multi-part and V2 checkpoints, `_last_checkpoint`, and log
  compaction files where they are listed (§4.2).
- Reader version 1 to 3 with the reader features `deletionVectors`,
  `columnMapping` in `name` mode, `timestampNtz` and `v2Checkpoint`.
  `columnMapping` in `id` mode, `catalogManaged` and any feature the
  package does not know are refused with a classed error naming it (D7).
- Reading with column selection and a filter that prunes files by
  partition values and statistics, then filters rows exactly.

**After 0.1.0:** the change data feed (`lake_cdf()`), `id`-mode column
mapping, row-group pruning from Parquet footers read by byte range,
other Azure authentication (SAS, shared key), Iceberg.

## 3. Position in the `zu*` family

- **`qio`** reads every Parquet file: checkpoints and data. It takes a
  local path, so `zulake` downloads a file before `qio` opens it (§4.3).
- **`zujson`** parses commits (`json_parse_ndjson()`) and the JSON
  strings inside them (`stats`, `schemaString`).
- **`zuhttp`** is the transport to Azure. It is not on CRAN; `zulake`
  0.1.0 waits for it (D5). Range requests and streamed bodies need
  nothing new from it.
- **`zuroar`** reads deletion vectors (`roar64_unserialize()`). Its
  planned bit vectors (pedrobtz/zuroar#71, zuroar 0.2.0) are 32-bit, so a
  keep mask built from them is an additive helper after 0.1.0, not the
  shape `lake_deletion_vectors()` returns (D12).
- **`zugodb`** calls `zulake`, never the reverse: once its Stage 10
  registered readers exist, an extension registers a `delta` format that
  opens a snapshot with `zulake` and streams the files.
- **`quak`** stays on `duckdb` and gains nothing it must adopt.

## 4. Architecture

### 4.1 Storage

One internal interface with two backends, local and Azure:

| Operation | Use |
| --- | --- |
| `list(prefix, after)` | `_delta_log/` entries from a version on |
| `get(path)` | commits, checkpoints, data files |
| `get_range(path, from, to)` | deletion vectors inside a shared file |
| `head(path)` | existence and size |

The Azure backend speaks the Blob service REST API (`List Blobs` with a
prefix and `marker`; `Get Blob` with `Range`), which also serves
hierarchical-namespace (ADLS Gen2) accounts, so one code path covers
both URI forms. Every request carries `Authorization: Bearer <token>`
and an `x-ms-version` header pinned in the package. The interface stays
internal so that a future `zustore` can replace the backend without
changing the public API (Q6).

### 4.2 Log replay

A snapshot at version `v` is built as the protocol prescribes:

1. Read `_delta_log/_last_checkpoint` if present; otherwise list the log.
2. List `_delta_log/` from the checkpoint's version on, and collect the
   commits up to `v`. For time travel by timestamp, resolve the version
   from `inCommitTimestamp` when the table has `inCommitTimestamp`
   enabled, otherwise from the commit files' modification times, as the
   protocol requires.
3. Read the checkpoint with `qio` (every part, and the sidecars of a V2
   checkpoint), then apply the commits in order. Checkpoints are nested
   Parquet, which `qio` cannot read yet (D14): until it can, replay
   starts at commit 0, and a table whose log no longer reaches commit 0
   is refused with a classed `zulake_error_checkpoint_unreadable`.
4. Reconcile: the latest `metaData` and `protocol` win; an `add` is live
   unless a later `remove` names the same path and deletion vector id;
   `txn` keeps the latest version per `appId`; `domainMetadata` keeps the
   latest per domain, dropping those marked `removed`.

The result is held in the snapshot object as data frames. The protocol's
`(path, deletionVector.uniqueId)` key is what identifies a logical file,
so a file rewritten with a new deletion vector is one live row, not two.

Settled in Stage 2 (2026-11-26), each where the protocol leaves a reader
a choice:

- *Inside one commit*, removes are applied before adds, so a logical file
  a commit both removes and re-adds is live afterwards. Why: actions in a
  commit have no order, and "remove and add the same file" can only mean
  "replace it" (new statistics, a metadata update).
- *Log compaction files* replace the commits they cover whenever one
  starts where replay stands and ends at or before the target version
  (the one reaching furthest, of several). Why: the protocol makes them
  equivalent to those commits; a log whose old commits were cleaned up
  but compacted still opens.
- *`_last_checkpoint`* is parsed and kept, but replay still starts at
  commit 0. One that is not JSON, has no whole `version`, or names a
  version past the last commit is a corrupt log. Why: a hint that
  contradicts the log means the log is not what its writer left.
- *Time travel by timestamp* opens the latest version whose commit time
  is at or before the timestamp, and the first version for a timestamp
  before every commit, as `deltalake` 1.7.0 does (its answers on every
  fixture). The commit time is `commitInfo.inCommitTimestamp` from
  `delta.inCommitTimestampEnablementVersion` on (version 0 without it)
  when in-commit timestamps are enabled in the latest snapshot, which
  must therefore pass the feature gate too, and the file's modification
  time otherwise. Why: the protocol's split at the enablement version
  gives the same answer under this rule, since in-commit timestamps only
  grow from there.
- *Partition values* of live files are checked against their column's
  type (the protocol's "Partition Value Serialization"; by physical name
  under column mapping) when the snapshot is built; a value that does
  not parse is a corrupt log. An empty string or a missing key is null.

### 4.3 Reading

`lake_read()` takes the live files, prunes them (§6), downloads each
survivor to a session cache, reads it with `qio` (columns selected by
physical name under column mapping, then renamed), drops the rows its
deletion vector marks, adds partition columns from the `add` action,
filters rows exactly, and binds the pieces. `lake_walk()` does the same
one file at a time and calls a function on each piece, for tables
larger than memory. Downloads are removed when the session ends unless
the `cache` argument names a directory (Q4).

### 4.4 Deletion vectors

A descriptor (`storageType`, `pathOrInlineDv`, `offset`, `sizeInBytes`,
`cardinality`) is resolved to bytes: inline (`i`) by Z85 decoding;
relative (`u`) by decoding the UUID to
`<prefix>/deletion_vector_<uuid>.bin`; absolute (`p`) as given. A file
holds a version byte, then per vector a big-endian size, the bitmap and
a CRC-32, read by range at `offset`. The bitmap is the little-endian
magic number 1681511377 followed by a portable 64-bit Roaring bitmap,
which `zuroar::roar64_unserialize()` reads. Row indexes are 0-based
positions in the Parquet file. The checksum is verified (D9).

## 5. Public R API (proposed)

Prefix `lake_`. A `zulake_table` is an immutable snapshot of one version.
Every inspection function returns a base data frame; nested values
(partition values, statistics, tags) are list columns.

```r
# Opening
lake_open(uri, version = NULL, timestamp = NULL, credentials = NULL)
lake_is_table(uri, credentials = NULL)
lake_load(tbl, version = NULL, timestamp = NULL)  # another snapshot

# The table
lake_version(tbl)        # the snapshot's version
lake_versions(tbl)       # every version still in the log, with timestamps
lake_history(tbl, limit = NULL)   # commitInfo, newest first
lake_metadata(tbl)       # id, name, description, format, created time
lake_schema(tbl)         # columns, Delta types, nullability, metadata
lake_partition_columns(tbl)
lake_properties(tbl)     # configuration, with protocol defaults filled in
lake_protocol(tbl)       # versions and features, each marked supported
lake_summary(tbl)        # one row: files, bytes, records, deleted rows

# Files
lake_files(tbl, filter = NULL, stats = TRUE)  # live add actions
lake_partitions(tbl, filter = NULL)           # distinct partition values
lake_removed(tbl)        # remove tombstones still in the log
lake_deletion_vectors(tbl, files = NULL, rows = TRUE)  # descriptors, rows
lake_count(tbl)          # records from stats, minus deleted rows

# The log itself
lake_log(tbl)            # every _delta_log entry: version, kind, size
lake_actions(tbl, version)                    # one commit, every action
lake_changes(tbl, from, to = lake_version(tbl))  # files added and removed
lake_transactions(tbl)   # txn: latest version per appId
lake_domains(tbl)        # domainMetadata
lake_checkpoints(tbl)    # checkpoints and _last_checkpoint

# Data
lake_read(tbl, columns = NULL, filter = NULL)
lake_walk(tbl, FUN, columns = NULL, filter = NULL)
```

`filter` is an unevaluated R expression over column names: `==`, `!=`,
`<`, `<=`, `>`, `>=`, `%in%`, `is.na()`, `!`, `&` and `|`, with literals
or values from the calling environment (`!!`-free; local values are
looked up there). That subset prunes. Any other call is allowed but only
filters rows after reading; `lake_files()` refuses it, since it has no
rows to filter (D8).

`credentials` is a function of no arguments returning a bearer token as
a single string. `zulake` calls it before the first request, and again
once after a `401` before failing. It never stores the token in the
snapshot, never prints it, and redacts it from errors (D4).

`version` is a whole number from 0 to 2^53 - 1 and `timestamp` a single
`POSIXct` (settled 2026-11-26, Stage 2: a character time would need a
parser and a zone rule of its own). Every error is a condition of class
`zulake_error` with one subclass per kind: `zulake_error_argument`,
`zulake_error_uri` (a scheme with no backend yet), `zulake_error_storage`,
`zulake_error_not_table`, `zulake_error_version`,
`zulake_error_corrupt_log`, `zulake_error_checkpoint_unreadable` and
`zulake_error_unsupported_feature`, whose `feature` field names the
feature (D7). Built with base `stop()` on a classed condition: the
package has no `rlang` or `cli` dependency.

### 5.1 Against `deltalake` 1.7.0

The read and inspection side of `DeltaTable`, mapped:

| `deltalake` | `zulake` | Note |
| --- | --- | --- |
| `DeltaTable(uri, ...)` | `lake_open()` | `credentials` |
| `is_deltatable()` | `lake_is_table()` | |
| `load_as_version()` | `lake_load()` | a new snapshot |
| `version()` | `lake_version()` | |
| `history(limit)` | `lake_history()` | |
| `metadata()` | `lake_metadata()` | (a) |
| `schema()` | `lake_schema()` | |
| `protocol()` | `lake_protocol()` | (b) |
| `file_uris()` | `lake_files()$uri` | |
| `get_add_actions()` | `lake_files()` | nested, no `flatten` |
| `partitions()` | `lake_partitions()` | |
| `count()` | `lake_count()` | stats minus DVs |
| `deletion_vectors()` | `lake_deletion_vectors()` | positions, not `selection_vector` (D12) |
| `transaction_version()` | `lake_transactions()` | every `appId` |
| `to_pyarrow_table()` | `lake_read()` | (c) |
| `to_pyarrow_dataset()`, `scan()` | `lake_walk()` | |
| `load_cdf()` | `lake_cdf()` | after 0.1.0 |

(a) `configuration` moves to `lake_properties()`. (b) Each feature is
marked as supported by `zulake` or not. (c) The filter is an R
expression, not `deltalake`'s DNF tuples or SQL string, and it prunes
as `file_pruning_predicate` does before filtering rows.
`lake_open(version =, timestamp =)` does what `DeltaTable(version =)`
and `load_as_version()` do. Seven functions have no counterpart in
`deltalake`: `lake_log()`, `lake_actions()`, `lake_changes()`,
`lake_removed()`, `lake_domains()`, `lake_checkpoints()` and
`lake_summary()`.

Left out on purpose: every write and maintenance method (`create`,
`delete`, `merge`, `update`, `vacuum`, `optimize`, `restore`, `repair`,
`alter`, checkpoint creation), `to_pandas()`'s engine choice, and SQL
predicate strings. `table_config` and `without_files` are deprecated in
1.7.0 and have no counterpart.

## 6. Pruning and filtering

A filter is first split into what can prune and what cannot. The
pruning part is evaluated per file, in three-valued logic, against:

- **partition values**, parsed from their strings with the column's
  Delta type as the protocol's partition value serialisation rules say,
  exactly, so pruning on a partition column is exact;
- **statistics** (`numRecords`, `minValues`, `maxValues`, `nullCount`),
  which give "cannot match", "may match" or "unknown". A file is dropped
  only on "cannot match". A missing statistic is "unknown". Statistics
  marked `tightBounds = false` (after deletion vectors) are still valid
  bounds for "cannot match".

Strings are compared in UTF-8 byte order, as the protocol's statistics
are; a truncated string maximum is never treated as exact. Rows of the
surviving files are then filtered with the whole expression in R. The
result is exact whatever the statistics say; statistics only decide how
much is downloaded.

## 7. Types

Delta's types map to what `qio` returns for the Parquet column, so
`zulake` adds no conversion of its own for data. For the log itself:
`long` statistics and versions are doubles, exact below 2^53, or an
`integer64` from `bit64` if asked (the `int64` argument, as in `qio`).
`timestamp` is `POSIXct` in UTC. `timestamp_ntz` is `POSIXct` with
`tzone = "UTC"`, and `lake_schema()` marks the column as zone-less.
`decimal` statistics stay as their JSON text, since a double would round
them (D10). Data columns `qio` cannot return (nested, until D14's `qio`
slice; anything beyond it after) are handled so that none is lost
silently (D7): with `columns = NULL` the readable columns are returned and
each unreadable one is named in a classed warning,
`zulake_warning_column_skipped`; a column named in `columns` that cannot
be returned is a classed error.

## 8. Testing and validation

- **Corpora (2026-11-26, Q3).** A small subset of `delta-rs`'s
  `crates/test/tests/data` tables (Apache-2.0), copied unchanged from
  commit `40439ad6d37a9e99add5bd80796aa6179ebe339f`, plus tables zulake
  writes itself with `deltalake` 1.7.0's writer (MIT) for what that subset
  lacks, each with its source and writer in
  `tests/testthat/fixtures/PROVENANCE.md`. They ship in the package,
  packed in one tar (their paths are longer than a package tarball
  allows), so the oracle tests run on CRAN too; the Apache notice is in
  `inst/COPYRIGHTS` and "The delta-rs authors" are a `cph`. DAT is not
  used: it has no licence. `COVID-19_NYT` is not copied (New York Times
  terms).
- **Oracle.** `deltalake` 1.7.0, installed with `uv` in a
  development-only workflow, answers the same questions on every
  fixture: version, history, schema, protocol, live file list, partition
  values, statistics, count, deletion vector row indexes and full reads.
  `zulake` must agree on every one. Fixtures it cannot read must be
  refused by name. The answers are committed
  (`tests/testthat/fixtures/answers/`, format in `tools/oracle/README.md`)
  and the `oracle` workflow regenerates them. Deliberate differences:
  `history()` is taken from the latest snapshot and cut at each version,
  because on an older snapshot 1.7.0 reports negative versions; and
  `deltalake` reads `columnMapping` in `id` mode, which `zulake` refuses
  (D7, Q7).
- **Hostile log.** Truncated and corrupt commits, a missing checkpoint
  part, a `_last_checkpoint` that points past the log, a deletion vector
  with a bad checksum, a magic number that differs, a partition value of
  the wrong type. Each is a classed `zulake_error`, never a wrong
  answer.
- **Azure** (D13), in three layers:
  - *Requests.* A `zu_mock_transport()` fake serves the local fixtures
    and records every request; tests assert method, path, query, `Range`,
    `Authorization` and `x-ms-version`. Runs in `R CMD check`.
  - *Emulator.* `azure-emulator.yaml`, the package's own workflow, needs
    no secrets: it uploads the fixtures to Azurite over HTTPS with
    `--oauth basic`, and `zulake` (bearer token) and `deltalake` read the
    same tables; snapshots and full reads must be equal. Cassettes are
    recorded from this run with `zu_cassette_transport()` and replayed in
    `R CMD check`, never written by hand. A cassette checks nothing about
    the request it answers, so the request assertions stay with the fake.
    The cassette key ignores `Range` (pedrobtz/zuhttp#353), so each ranged
    request gets its own cassette until that is fixed.
  - *Live.* A suite against a real ADLS Gen2 account, run only when
    `ZULAKE_AZURE_URI` and a token are set, by `azure-live.yaml` on
    dispatch or by the maintainer locally; it never runs on CRAN.

  Azurite URLs are path-style (`https://127.0.0.1:10000/devstoreaccount1/`),
  so tests reach it through an internal option, `zulake.azure_endpoint`;
  the public API still refuses other schemes (D3).
- **Filters.** A property test: for random filters over the fixtures,
  `lake_read(filter = f)` equals reading everything and subsetting in R.

## 9. Roadmap

The order of work, and what 0.1.0 waits for, are in
[roadmap.md](roadmap.md).

## 10. Decisions

- **D1.** Pure R. The log is JSON and Parquet, which `zujson` and `qio`
  already read; no compiled code.
- **D2 (maintainer, 2026-11-25).** Inspection is the primary purpose:
  every action of the log is reachable, unchanged, as a data frame.
  Reading with filters is the convenience on top, shaped on `deltalake`.
- **D3 (maintainer, 2026-11-25).** Azure is the remote store, and the
  only one tested. Local paths are supported for fixtures; other schemes
  are refused in 0.1.0.
- **D4 (maintainer, 2026-11-25).** Authentication is a user-supplied
  `credentials()` function returning a bearer token. `azr` is not a
  dependency. SAS and shared-key signing come after 0.1.0.
- **D5 (maintainer, 2026-11-25).** The transport is `zuhttp`, not
  `httr2` or `curl`, and 0.1.0 waits for it.
- **D6 (maintainer, 2026-11-25).** `zulake` does not depend on `zugodb`;
  `zugodb` or an extension calls `zulake`.
- **D7.** Unsupported reader features are refused by name, before any
  data is read, never ignored: reading past `columnMapping` in `id` mode
  or past deletion vectors silently returns wrong rows.
- **D8.** Filters are R expressions, not `deltalake`'s DNF tuples; the
  pruning subset is fixed and documented, and anything outside it only
  filters rows.
- **D9.** Deletion vectors are in 0.1.0, because tables written by
  Databricks use them by default and refusing them would refuse most
  Azure tables. Their CRC-32 is verified.
- **D10.** Values that would lose precision in the log (decimal
  statistics, 64-bit counts above 2^53 without `int64 = "integer64"`)
  stay exact or are an error, as in `qio`.

- **D11 (maintainer, 2026-11-25).** The name is `zulake`: Delta in 0.1.0,
  Iceberg in a later version. The `lake_` functions, the snapshot class
  and the data frames they return are therefore named for a table, not
  for Delta, and a snapshot records its format, so that Iceberg can be
  added without renaming anything. Iceberg needs `zuavro` (RFC 0063) for
  its manifests.
- **D12 (2026-11-26).** `lake_deletion_vectors(tbl, files = NULL,
  rows = TRUE)` returns a base data frame with one row per live file
  that has a deletion vector: `uri`, the descriptor (`storage_type`,
  `path_or_inline_dv`, `offset`, `size_in_bytes`, `cardinality`) and
  `rows`, a list column of sorted 0-based Parquet row positions as
  doubles. A position at or above 2^53 is a classed error (D10).
  `rows = FALSE` returns the descriptors only, with no I/O and no
  `zuroar`. Why: a `zuroar64` column is an external pointer that cannot
  print, compare or be saved without `zuroar`, which is only suggested
  (D2), and the 32-bit `zuroar_bits` of pedrobtz/zuroar#71 does not hold
  64-bit vectors. The oracle comparison is `which(!selection_vector) - 1`.
- **D14 (2026-11-26).** Checkpoints and sidecars are read by `qio`, and
  0.1.0 waits for a `qio` that reads structs, maps and lists of
  repetition level 1 (pedrobtz/qio#73). Until then replay starts at
  commit 0, and a table that needs a checkpoint is refused with a classed
  error. Data files are read meanwhile: flat columns as `qio` returns
  them, nested ones left out with a classed warning naming each, or a
  classed error when the caller named one in `columns` (§7, D7). Why:
  carquet already decodes the leaf streams and nested assembly is `qio`'s
  by its own design, while a commits-only 0.1.0 would refuse most
  Databricks tables, whose log cleanup removes old commits. D1 stands.
- **D13 (2026-11-26, provisional).** Azurite over HTTPS with
  `--oauth basic` is the CI stand-in for Azure; a live ADLS Gen2 run is
  the release gate (§11, criterion 4b). Why: no storage account or token
  is available yet, and Azurite is an independent implementation of the
  Blob REST API. A spike at the start of Stage 6 confirms that Azurite
  accepts bearer tokens through `zuhttp`; if it does not, the request
  fake and criterion 4b are the only Azure oracles, and Stage 6 cannot
  close until a real account exists.

## 11. Acceptance criteria for v0.1.0

1. Agrees with `deltalake` 1.7.0 on every supported fixture of §8, and
   refuses every unsupported one by feature name.
2. `lake_read(filter = f)` equals a full read subset in R for every
   filter in the property test.
3. Rows marked by deletion vectors never appear in a read.
4. Azure, in two parts (D13):
   - **4a.** The emulator suite passes against Azurite with a bearer
     token, and no token appears in any output, error, snapshot or
     cassette.
   - **4b.** The live suite passes once against a real ADLS Gen2 account,
     by a dispatched `azure-live.yaml` run or a maintainer's local run
     with its log attached to pedrobtz/zulake#24. Dropping 4b is the
     maintainer's decision; it amends D3, and the README then says
     "tested against Azurite, not live Azure".
5. `R CMD check --as-cran` clean on all r-actions legs.

## 12. Open questions

- **Q1.** Settled 2026-11-25 as D11: `zulake`, Delta now, Iceberg
  later.
- **Q2.** Settled 2026-11-26 as D12: descriptors plus `rows`, 0-based
  row positions as doubles; a keep mask is an additive helper after
  pedrobtz/zuroar#71.
- **Q3.** Settled 2026-11-26 (maintainer): `delta-rs`'s test tables, a
  small subset shipped in the package, under Apache-2.0; no DAT tables,
  because DAT has no licence (no LICENSE file, nothing in its README or
  packaging, checked 2026-11-26) and so cannot be redistributed (§8).
- **Q4.** Should downloads be cached across sessions (for example
  through `dazcache`), keyed by path and the `add` action's size and
  modification time, which never change for a Delta data file?
- **Q5.** Provisionally settled 2026-11-26 as D13: yes, Azurite over
  HTTPS with `--oauth basic`, confirmed by a spike at the start of
  Stage 6.
- **Q6.** Should `List Blobs` be replaced by probing successive commit
  names after the checkpoint, as Delta kernels can, when listing is
  slow on large logs? Blob listing has no "start after" for an arbitrary
  name beyond the prefix and continuation marker, which was not
  verified for this RFC.
- **Q7.** Does `qio` read Parquet field IDs, which `id`-mode column
  mapping needs? Settles when that mode can be supported.

## 13. Sources and verification

Checked on 2026-11-25: `crandb.r-pkg.org/zulake` (`not_found`);
`gh repo view pedrobtz/zulake` (not found); `PROTOCOL.md` at
`delta-io/delta` `483d55e`, sections Deletion Vector Files, Deletion
Vector Descriptor Schema, Deletion Vector Format, Deletion Vector File
Storage Format and the appendix of valid feature names; `deltalake`
1.7.0's `python/deltalake/table.py` at `python-v1.7.0` (constructor,
`version`, `partitions`, `file_uris`, `load_as_version`, `load_cdf`,
`scan`, `deletion_vectors`, `schema`, `metadata`, `protocol`, `history`,
`count`, `to_pyarrow_table`, `get_add_actions`, `transaction_version`;
its `SUPPORTED_READER_FEATURES` for the pyarrow engine are
`timestampNtz`, `v2Checkpoint`, `variantType` and
`variantType-preview`, and its `datafusion` engine also reads column
mapping and deletion vectors); the `NAMESPACE` files of `qio`, `zuhttp`
and `zujson` and `qio`'s `read_parquet()`, `open_parquet()` and
`walk_batches()` signatures; `zuroar`'s `roar64_unserialize()`. The
Azure REST details in §4.1 (`List Blobs`, `Get Blob` with `Range`,
`x-ms-version`) are from the service's public API and were not
exercised for this RFC.

[sketch]: https://github.com/pedrobtz/packages/blob/main/rfcs/more-candidates.md#3-zulake-promoted-to-rfc-0081

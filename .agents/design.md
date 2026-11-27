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
  `columnMapping` in `name` mode, `timestampNtz`, `v2Checkpoint` and
  `vacuumProtocolCheck`. `columnMapping` in `id` mode, `catalogManaged`,
  `typeWidening`, `variantType`, `variantShredding` and any feature the
  package does not know are refused with a classed error naming it (D7).
  Writer features are never a reason to refuse: `zulake` does not write.
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

Settled in Stage 6 (2026-11-26):

- **URIs.** `abfss://<container>@<account>.dfs.core.windows.net/<path>`,
  `https://<account>.dfs.core.windows.net/<container>/<path>` and
  `https://<account>.blob.core.windows.net/<container>/<path>` all become
  requests to `https://<account>.blob.core.windows.net/<container>/`.
  Account names are 3 to 24 lowercase letters and digits (the host is
  lower-cased), container names 3 to 63 lowercase letters, digits and
  single hyphens (or `$root`), as Azure defines them; a path segment `.`,
  `..` or empty, a query string (a SAS) and user information are refused
  with `zulake_error_uri`, whose message never repeats the query or the
  user information. `abfs://`, `wasbs://`, `http://`, other hosts
  (sovereign clouds included) and other schemes are refused too (D3).
  Why: the three forms are what Databricks, Synapse and `deltalake`
  print; anything else is a guess at an endpoint.
- **Requests.** `x-ms-version: 2023-11-03`, the version `object_store`
  (`deltalake`'s storage layer) sends. `List Blobs` with `prefix`,
  `delimiter=/` and `include=metadata`, following `NextMarker` until it is
  empty, so `list()` sees only the directory's own files; a blob whose
  metadata says `hdi_isfolder=true` (a directory of a hierarchical
  namespace) is not a file, and neither is a `BlobPrefix`. A marker that
  repeats, any marker seen before in the listing and not only the last
  one, is an error, not a loop (2026-11-27, #45). `after` is applied to the listing, as
  Q6 says Blob listing cannot start after a name. `ContainerNotFound`
  on the first page lists nothing, as a missing local directory does, so
  `lake_is_table()` is `FALSE` and `lake_open()` a
  `zulake_error_not_table`; on a later page it is a `zulake_error_storage`,
  since the listing would hold part of the log (2026-11-27, #46). `Get Blob` is
  sent with `decode = FALSE` (the stored bytes, whatever their
  `Content-Encoding`), no body limit and a 600-second timeout. A range
  needs `206` with exactly `to - from + 1` bytes; a short body or `416` is
  a `zulake_error_storage`, as reading past a local file's end is.
- **Credentials (D4).** `credentials()` is called before the first request
  of a snapshot's backend and once more after a `401`; the new token is
  kept for later requests. A second `401`, or a `403`, is a
  `zulake_error_auth` with `status` and Azure's `code`; anything else
  unexpected is a `zulake_error_storage` with the same fields; a transport
  failure is a `zulake_error_storage` with zuhttp's message and class name
  (`reason`), not its condition, which holds the request. `credentials()`
  must return one string; a leading `Bearer ` in any case is dropped, and
  what is left must be non-empty, without spaces or control characters
  (checked after the drop, so `"Bearer "` is no token: 2026-11-27, #47);
  otherwise, or if it fails, `zulake_error_auth`.
  `credentials = NULL` sends anonymous requests (a public container) and
  never retries. The token and the function live in a package-level
  registry keyed by an id; the snapshot holds only a handle with that id
  and its table's URI, whose finalizer removes the entry. So `serialize()`
  of a snapshot carries neither, even when the function's environment
  holds the token as a literal, and a snapshot restored in another session
  gets `zulake_error_auth` on its next request. An id is a random 128-bit
  nonce made once per session and a counter, and an entry answers only a
  handle with its own table's URI (2026-11-27, #43: ids counted from 1 in
  every session, so a restored snapshot found another session's entry and
  sent its token to the saved account). Why: a `function() token`
  closure in the snapshot would put the token in every `saveRDS()`. The
  registry is made in `.onLoad()`, and the backend's functions carry no
  srcref and its frame no argument promises: with the package's source
  kept (covr, `R_KEEP_PKG_SOURCE=yes`), a srcref reached the lazy-load
  loader's environments, which hold every environment the build made,
  the registry included (found on CI in Stage 6); a test asserts the two
  environments a snapshot serializes.
- **Absolute paths in the log.** An `add` path or a deletion vector path
  that is one of the three Azure URI forms is read through the Blob
  endpoint of its own account and container with the table's credentials,
  when the table is on Azure; on a local table it stays a
  `zulake_error_uri`. A table's files stay on its own backend: a local
  path or a `file:` URI in the log of a table on Azure is a
  `zulake_error_uri` too, never read from the reader's disk (2026-11-27,
  #44). An absolute Azure path is read only when it names the table's own
  account and container (in any of the three forms, the host in any case);
  another account or container is a `zulake_error_uri` before any request,
  with no opt-in in 0.1.0 (2026-11-27, #76: otherwise the log, which may
  be untrusted, chooses which accounts receive the table's token; shallow
  clones across accounts can get an opt-in later).

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
   Parquet, which `qio` reads from 0.1.2.9000 on (D14; Stage 2b).
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
- *`_last_checkpoint`* is parsed and kept. One that is not JSON, has no
  whole `version`, or names a version past the last commit is a corrupt
  log. Why: a hint that contradicts the log means the log is not what its
  writer left.
- *Time travel by timestamp* opens the latest version whose commit time
  is at or before the timestamp, and the first version for a timestamp
  before every commit, as `deltalake` 1.7.0 does (its answers on every
  fixture). The commit time is `commitInfo.inCommitTimestamp` from
  `delta.inCommitTimestampEnablementVersion` on (version 0 without it)
  when in-commit timestamps are enabled in the latest snapshot, which
  must therefore pass the feature gate too, and the file's modification
  time otherwise. Why: the protocol's split at the enablement version
  gives the same answer under this rule, since in-commit timestamps only
  grow from there. File times are first made increasing, as Delta's
  history manager and `deltalake` 1.7.0 make them: a commit whose file
  time is not after the previous commit's counts as 1 ms after it, in
  `lake_open(timestamp =)`, `lake_versions()`, `lake_history()` and a
  snapshot's `timestamp` alike (2026-11-27, #52: a copy that drops file
  times opened another version than `deltalake`; fixture `zl-file-times`).
  A log with no commit file (checkpoints alone) keeps no commit time:
  timestamp travel on it is a `zulake_error_version` (2026-11-27, #51).
- *File times* (settled 2026-11-26, Stage 5). File modification times
  are read through R, which on Windows is exact only to about 1 µs;
  zulake rounds to 10 µs and then truncates to milliseconds, so a file
  time within 5 µs below a millisecond boundary counts as the next
  millisecond. With inCommitTimestamp this does not apply.
- *Checkpoints* (settled 2026-11-26, Stage 2b). Replay starts from the
  latest whole checkpoint at or before the version, found in the listing
  (which zulake reads whole anyway), so a stale `_last_checkpoint` changes
  nothing; then the commits after it. Whole means a classic or V2 file, or
  every part of a multi-part set; a set with a part missing is passed
  over. Why: the protocol makes a checkpoint equal to the commits it
  stands for, and the latest one reads least.
  - A `_last_checkpoint` naming a version with no whole checkpoint (a part
    missing) is a corrupt log at every version, like one past the log.
    `deltalake` 1.7.0 refuses the versions from the hint on and opens the
    earlier ones; zulake refuses the log, so that its answer does not
    depend on the version asked (on the advice of a design review agent).
  - A checkpoint that cannot be read (a file gone, bytes `qio` refuses, a
    sidecar outside `_delta_log/_sidecars/`, an integer past 2^53 without
    `bit64`) is passed over for an earlier one or for commit 0, which hold
    the same state. `zulake_error_checkpoint_unreadable` is left for a
    version whose replay needs commit 0, when commit 0 is gone and the
    checkpoint at or before the version is not whole or cannot be read; it
    carries the `checkpoint` version and the read failure as `parent`. A
    checkpoint that reads but whose actions break the protocol is a corrupt
    log, like a commit. An authentication failure is never passed over.
    Only read failures are passed over: a `zulake_error`, an error of
    `qio`'s, or a refusal of the checkpoint reader's own (internal class
    `zulake_checkpoint_refusal`); any other error propagates unchanged
    (2026-11-27, #89: a bug in zulake's checkpoint code was hidden as an
    unreadable checkpoint).
  - A version older than the earliest checkpoint whose commits were
    cleaned up is a `zulake_error_version`: it is no longer in the log
    (a fact about the table, not a reading failure).
  - A log of checkpoints alone (or one whose commit at the snapshot's
    version is gone) opens, with `timestamp` `NA` and no `commit_info`:
    the checkpoint determines the state, and log cleanup can leave this.
  - *What is read.* The `protocol`, `metaData`, `txn`, `domainMetadata`,
    `remove`, `add` and `sidecar` columns, selected by group path; not
    `commitInfo`, `cdc`, `checkpointMetadata`, nor `stats_parsed` and
    `partitionValues_parsed`. Statistics come from the `stats` JSON string
    and partition values from `partitionValues`, as in a commit, so one
    parser serves both and any user type in `stats_parsed` is never a
    reason to fail. A file whose checkpoint has `stats_parsed` but no
    `stats` (`delta.checkpoint.writeStatsAsJson = false`) shows no
    statistics and is never pruned on them (design §6: statistics only
    decide what is downloaded).
  - *One representation.* A checkpoint row becomes the list zujson gives
    the same action as JSON: an optional struct qio marks null is no
    action or field, a struct of nulls an object without those fields; a
    `LIST` a vector (an empty one `logical(0)`); a `MAP` a named list with
    `NULL` for a null value (an empty one an empty named list); a whole
    number an R integer holds an integer, one past 2^53 - 1 the marked
    digits of `R/int64.R` (qio's `integer64` read, when a double read
    warns), another a double. Tombstones in a checkpoint are tombstones.
    So the gate, the partition checks and every inspection function see
    what they see from commits. What differs is what checkpoint writers
    rewrite in their copy of an `add`: `dataChange` (Spark and Databricks
    write `false`), an empty `tags` map for a null one, field order, and
    null fields left out where a commit may write them. `lake_files()`
    reports that copy, the action as the log now holds it (D2), so
    `data_change` describes the commit only when the add came from a
    commit; `a[["x"]]` reads an absent and a null field alike. A
    checkpoint also holds only the tombstones its writer had not expired.
    Tested against replay from commit 0 on every checkpoint fixture, at
    every version, and against `deltalake` 1.7.0's answers.
- *Partition values* of live files are checked against their column's
  type (the protocol's "Partition Value Serialization"; by physical name
  under column mapping) when the snapshot is built; a value that does
  not parse is a corrupt log. Dates and times are checked by the parser
  that converts them (calendar dates, hours 0-23, minutes and seconds
  0-59, offsets to 18:00), which statistics and filter literals use too,
  and a time is the double qio reads for the same microseconds: the count
  rounded once, then divided by 1e6 (2026-11-27, #53, #54). An empty string or a missing key is null.

### 4.3 Reading

`lake_read()` takes the live files, prunes them (§6), downloads each
survivor to a session cache, reads it with `qio` (columns selected by
physical name under column mapping, then renamed), drops the rows its
deletion vector marks, adds partition columns from the `add` action,
filters rows exactly, and binds the pieces. `lake_walk()` does the same
one file at a time and calls a function on each piece, for tables
larger than memory. Data files on local disk are read in place; a backend
without local paths (Azure) downloads each file once per session, keyed by
path, size and modification time, into the session's temporary
directory, which R removes when the session ends. Caching across sessions
is Q4, after 0.1.0 (settled 2026-11-26, Stage 4: no `cache` argument in
0.1.0, since a per-session cache needs none). Every file left after
pruning is downloaded before the first piece, by `lake_walk()` too, and the
disk this uses, the pruned files' size, is documented in `?lake_walk`
rather than bounded: larger than memory, not larger than disk (2026-11-27,
#75: plans before rows is the design's order, and fetching per piece or
reading footers by range is a later change).

Settled in Stage 4 (2026-11-26):

- *Order.* Refusals, then the filter plan, pruning, each surviving file's
  `qio::read_plan()`, and the columns returned, all before a row is read;
  then per file: read, partition columns added, a column the file lacks
  filled with `NA` of its type, rows filtered. Stage 5 drops the rows a
  deletion vector marks between the read and the row filter.
- *Deletion vectors and column mapping on rows* (Stage 5, 2026-11-26,
  replacing Stage 4's refusal of both). The deletion vectors of the files
  that survive pruning are read and checked after the read plans and
  before any data file, so a corrupt one returns no rows (from
  `lake_walk()` too); a pruned file's vector is never read. `name`-mode
  column mapping reads each column by its physical name and returns it by
  its logical name; a column a file lacks is `NA`, as the protocol asks.
  In `name` mode a top-level field without a non-empty
  `delta.columnMapping.physicalName` is a `zulake_error_corrupt_log`
  naming the field (field `column`), checked once when the snapshot is
  built; the logical name is never used in its place (2026-11-27, #77:
  the protocol requires the physical name in `name` mode, and after a
  rename the logical name can be another column's in the files; hostile
  log `column-mapping-no-physical-name`).
- *`int64`.* `lake_read()` and `lake_walk()` take `int64` like the
  inspection functions, since a `long` partition column holds 64-bit
  values from the log (§5), and pass it to `qio` for data columns.
- *Row filter* (settled 2026-11-26, replacing Stage 4's "an expression
  that looks at other rows sees one file at a time"). A filter is row-wise
  by construction (D8, §6), so evaluating it per file equals evaluating it
  on the whole table, and `lake_read()` equals binding `lake_walk()`'s
  pieces.

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

Settled in Stage 5 (2026-11-26):

- *Location.* A `u` path is `<prefix>/deletion_vector_<uuid>.bin` under
  the table root (no `/` without a prefix), the UUID in lower-case
  canonical form from the last 20 Z85 characters. A `p` path is read like
  an absolute `add` path: a local path or `file:` URI, any other scheme a
  `zulake_error_uri` until Stage 6. An absent `offset` is 0, as the
  protocol says. Inline bytes are decoded whole and cut to `sizeInBytes`
  (Delta pads them to a multiple of 4).
- *Checks.* Each is a `zulake_error_corrupt_log` (field `file`, the data
  file), with no rows returned: Z85 that is not Z85; a file that does not
  exist, or a vector running past its end (checked against `head()`'s size
  before reading); a format version byte other than 1 (read once per file
  per call); a stored size other than `sizeInBytes`; a CRC-32 (IEEE, as
  zlib) other than the stored one; a magic number other than 1681511377; a
  bitmap `zuroar` rejects; a bitmap whose size is not `cardinality`; a row
  at or past the data file's row count. A row at or above 2^53 is a
  `zulake_error_int64` (D12). Why: each is a vector that does not say what
  its descriptor says, and applying it could return deleted rows.
- *Only the portable format.* The protocol's Deletion Vector Format
  defines magic 1681511377 (portable 64-bit Roaring). Example 3 of its
  descriptor schema is in Delta's other, "native" format (magic
  1681511376, big-endian), which the format section does not define; it is
  refused as above, not guessed at. Why: the protocol is the
  specification, and Delta's writers use the portable format.
- *`zuroar` absent.* Reading rows of a deletion vector (`lake_read()`,
  `lake_walk()`, `lake_deletion_vectors(rows = TRUE)`) needs `zuroar`;
  without it, a call that has a vector to read is a
  `zulake_error_missing_package` (field `package = "zuroar"`) before any
  data file is read. `lake_count()`, `lake_files()` and
  `lake_deletion_vectors(rows = FALSE)` need only the log.
- *CRC-32 in R.* Table-driven, about 5 µs a byte; a vector of 1 MB takes
  some seconds. Why: D1, and no hard dependency exports one.

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
lake_history(tbl, limit = NULL, int64)   # commitInfo, newest first
lake_metadata(tbl)       # id, name, description, format, created time
lake_schema(tbl)         # columns, Delta types, nullability, metadata
lake_partition_columns(tbl)
lake_properties(tbl)     # configuration, with protocol defaults filled in
lake_protocol(tbl)       # versions and features, each marked supported
lake_summary(tbl, int64) # one row: files, bytes, records, deleted rows

# Files
lake_files(tbl, filter = NULL, stats = TRUE, int64)  # live add actions
lake_partitions(tbl, filter = NULL, int64)    # distinct partition values
lake_removed(tbl, int64) # remove tombstones still in the log
lake_deletion_vectors(tbl, files = NULL, rows = TRUE)  # descriptors, rows
lake_count(tbl, footers = FALSE)  # records from stats, minus deleted rows

# The log itself
lake_log(tbl)            # every _delta_log entry: version, kind, size
lake_actions(tbl, version, int64)             # one commit, every action
lake_changes(tbl, from, to = lake_version(tbl), int64)  # files added and removed
lake_transactions(tbl, int64)   # txn: latest version per appId
lake_domains(tbl)        # domainMetadata
lake_checkpoints(tbl)    # checkpoints and _last_checkpoint

# Data
lake_read(tbl, columns = NULL, filter = NULL, int64)
lake_walk(tbl, FUN, columns = NULL, filter = NULL, int64)
```

`filter` is an unevaluated R expression over column names: `==`, `!=`,
`<`, `<=`, `>`, `>=`, `%in%`, `is.na()`, `!`, `&` and `|`, with literals
or values from the calling environment (`!!`-free; local values are
looked up there). That subset prunes. A filter may also apply these
row-wise functions to columns: `+ - * / %% %/% ^`, `abs`, `round`,
`floor`, `ceiling`, `sqrt`, `exp`, `log`, `nchar`, `toupper`, `tolower`,
`substr`, `startsWith`, `endsWith`, `grepl`, `is.nan`, `is.finite`, `xor`,
`as.character`, `as.numeric`, `as.integer`; and compare two columns. These
filter rows after reading and never prune; `lake_files()` and
`lake_partitions()` refuse them. Any other call with a column inside it
(`max`, `mean`, `rank`, `cumsum`, `duplicated`, `%in%` with a column on the
right, `[`, a user function) is a `zulake_error_filter` everywhere: a
filter is decided row by row, so its result does not depend on how rows are
split into files. A subexpression that names no column is a value,
evaluated once in the caller's environment, and may be any R (settled
2026-11-26, a correction to Stage 4, D8). Before R 4.3.0, `as.character`,
`substr`, `toupper`, `tolower` and `grepl` with a `timestamp` or
`timestamp_ntz` column inside are a `zulake_error_filter`, and `Depends`
stays at R >= 3.5.0 (2026-11-27, #74: there `as.character()` of a POSIXct
picks one format for the whole vector, date only when every value is at
midnight and no fraction of a second, so a row's text depended on the
other rows of its file, which is not row-wise).

`lake_count(tbl)` is the sum of `numRecords` over the live files minus
the cardinality of their deletion vectors, from the log alone. `stats` is
optional in the protocol: when any live file has no `numRecords` the
result is `NA_real_`, with a classed warning
(`zulake_warning_count_unknown`) giving the number of such files, which
`lake_summary()` also reports as `files_without_records`. It is never a
partial sum (`deltalake` 1.7.0 returns 0 for `simple_table` at version 0,
which has 5 rows). `footers = TRUE` reads the row counts of those files
from their Parquet footers (Stage 4), with no warning. A file with a deletion vector and
no `numRecords` is a corrupt log. The cardinality is the descriptor's,
which the log holds, so the subtraction needs no `zuroar` and is done from
Stage 3 on (settled 2026-11-26); Stage 5 adds the rows themselves.
A snapshot's print shows a size or record count it cannot compute as
"unknown" rather than failing: it catches the `zulake_error` that
`lake_summary()` and `lake_count()` raise, which is a
`zulake_error_int64` (a size or count past 2^53 - 1) or a
`zulake_error_corrupt_log` (statistics that are not JSON) (2026-11-27,
#90: a print method that fails hides the snapshot itself, and the
inspection functions still raise the error).

Settled in Stage 3 (2026-11-26), the shapes the roxygen documents in full:

- *Frames.* `lake_files()`: `path`, `uri`, `size_bytes`,
  `modification_time`, `data_change`, `partition` (list of typed values),
  `deletion_vector` (the five descriptor fields, `NULL` where absent), with
  `stats = TRUE` `num_records`, `null_count`, `min`, `max`, and last
  `action`, the `add` action unchanged (D2). `lake_changes()` is
  `lake_files(stats = FALSE)` with a first column `change`. `lake_removed()`:
  `path`, `deletion_timestamp`, `data_change`, `size_bytes`,
  `partition_values` (as the log writes them), `deletion_vector`, `action`.
  `lake_history()`: `version`, `timestamp`, `operation`, `commit_info`.
  `lake_actions()`: one row per action, `version`, `line`, `type`,
  `action`. `lake_schema()`: `name`, `type` (a nested type is `"struct"`,
  `"array"` or `"map"`, with the type itself in `type_detail`),
  `nullable`, `partition`, `physical_name`, `metadata`. `lake_protocol()`:
  one row per requirement (`readerVersion`, `writerVersion`, then each
  feature) with `reader`, `writer`, `version` and `supported`; the
  `zulake_error_unsupported_feature` condition carries the same frame as
  `protocol`, since a snapshot exists only when every row is supported.
  `lake_properties()`: `key`, `value`, `default`, filling in only the
  defaults the protocol states. `lake_partition_columns()` is a character
  vector. Why: names follow `deltalake`'s `get_add_actions()` where it has
  one, and the action itself stays reachable unchanged.
- *Times* from the log (`modificationTime`, `deletionTimestamp`,
  `createdTime`, commit times) are `POSIXct` in UTC. A version's
  `timestamp` is its commit time as the protocol defines it (in-commit
  timestamp or file modification time), the one `lake_open(timestamp =)`
  uses; the raw `commitInfo.timestamp` stays in `commit_info`.
- *64-bit values.* `int64 = c("double", "integer64")` on every function
  that returns 64-bit counts or values from the log JSON. Integers past
  2^53 - 1 are kept as text when the log is parsed (`zujson` rounds them
  otherwise) and become a `zulake_error_int64` as doubles or an exact
  `integer64`. `bit64` holds -2^63 + 1 to 2^63 - 1 (-2^63 is its `NA`), so
  -2^63 is an error in both modes. The exception is a `long` statistic in
  `lake_files(stats = TRUE)`'s `min` and `max`: one the mode cannot hold
  is `NA`, with a classed `zulake_warning_int64` (fields `value`, `column`,
  `path`) once per column, in both modes, and its exact digits stay in
  `action$stats` (settled 2026-11-26, Stage 4: a statistic is a bound, not
  a count, so a table whose writer recorded -2^63 must still list its
  files; `zl-types` does). Versions, counts and sizes keep the error.
  Pruning never converts: it compares `long` statistics and partition
  values as integer text (§6). Inside an action or `commitInfo` as the
  log writes it, only a value a double cannot hold becomes an
  `integer64`. `byte` and `short` values are integers, `integer` values
  doubles, because an R integer cannot hold -2^31. Why: D10, and `bit64`
  is only suggested.
- *Statistics* are keyed by logical column name (deltalake's
  `get_add_actions()` uses physical names under column mapping) and typed
  by the column's Delta type; a `decimal` statistic is the JSON number's
  text exactly (D10).
- *Filters in Stage 3.* `lake_files()` and `lake_partitions()` take the
  pruning subset of D8. Each file gets the set of outcomes the filter can
  have on its rows (TRUE, FALSE, NA, combined by R's three-valued logic);
  a comparison on partition columns has the one outcome the file's
  partition values give, and one on any other column the outcomes its
  statistics allow (Stage 4, §6). A file is kept when TRUE is possible.
  Partition values compare by §6's rules: `long` and `decimal` ones exactly
  at any precision (settled 2026-11-26, Stage 4, replacing Stage 3's
  "compared as a double"). Anything outside the subset is a
  `zulake_error_filter` in `lake_files()` and `lake_partitions()`, which
  have no rows; `lake_read()` and `lake_walk()` apply the row-wise
  functions to rows only and refuse every other call (settled 2026-11-26).

`credentials` is a function of no arguments returning a bearer token as
a single string. `zulake` calls it before the first request, and again
once after a `401` before failing. It never stores the token in the
snapshot, never prints it, and redacts it from errors (D4).

`version` is a whole number from 0 to 2^53 - 1 and `timestamp` a single
`POSIXct` (settled 2026-11-26, Stage 2: a character time would need a
parser and a zone rule of its own). Every error is a condition of class
`zulake_error` with one subclass per kind: `zulake_error_argument`,
`zulake_error_uri` (a URI or a path in the log that zulake will not open: a scheme with no backend, user information, a bad account, container or path segment, an absolute path off the table's storage; wording settled 2026-11-27, #91), `zulake_error_storage`,
`zulake_error_not_table`, `zulake_error_version`,
`zulake_error_corrupt_log`, `zulake_error_checkpoint_unreadable`,
`zulake_error_unsupported_feature`, whose `feature` field names the
feature (D7) and `protocol` field holds the `lake_protocol()` frame,
`zulake_error_int64` (a value a double cannot hold, D10; `value` gives its
digits), `zulake_error_filter` (a filter outside the pruning subset, or
a value it cannot compare exactly) and `zulake_error_column_unreadable` (a
column named in `columns` or used in `filter` that `qio` cannot return,
§7; fields `column`, `reason`) and `zulake_error_missing_package` (a
suggested package the call needs, `zuroar` for deletion-vector rows;
field `package`, Stage 5). The warnings, each also of class
`zulake_warning`, are `zulake_warning_count_unknown` from `lake_count()`,
`zulake_warning_int64` from `lake_files()` (a `long` statistic shown as
`NA`) and `zulake_warning_column_skipped` from `lake_read()` and
`lake_walk()` (fields `column`, `reason`). Built with base `stop()` and
`warning()` on classed conditions: the package has no `rlang` or `cli`
dependency.

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
| `count()` | `lake_count()` | stats minus DVs; `NA`, not a partial sum, without stats |
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

Settled in Stage 4 (2026-11-26), how values compare. Each comparison of
the pruning subset is made by one implementation on partition values, on
statistics and on rows, so pruning and the row filter cannot disagree:

- *Exact comparator.* `byte`, `short`, `integer`, `long` and `decimal`
  columns compare as decimal text. A value is parsed from
  `[+-]digits[.digits][e[+-]n]` (the exponent form is accepted: `zl-types`
  has `"dec38":1.234567890123457e+19`) into a sign, its digits without
  leading or trailing zeros and the position of the point (zero has sign
  0), and two values compare by sign, then the position, then the digits
  code point by code point, never by the locale's string `<`. Literals:
  integer, `integer64` and character values are exact (a character value
  that is not a number is a `zulake_error_filter`); a finite double `x` is
  `sprintf("%.15g", x)` when `as.numeric()` of that equals `x`, otherwise
  `sprintf("%.0f", x)` when `x` is whole, otherwise a
  `zulake_error_filter` asking for the value as text (`0.1` and `12.3`
  pass; `1/3` and `0.1 + 0.2` do not; R has already rounded a literal
  such as `9007199254740993` to 9007199254740992 before zulake sees it,
  which `?lake_read` says, with "exact up to 2^53 - 1" for `int64`:
  wording settled 2026-11-27, #91); `Inf` and `-Inf` compare as
  infinities; `NA` and `NaN` give `NA`. Partition values compare exactly at
  any precision. With `int64 = "integer64"` no non-whole double reaches
  `bit64` (`bit64::as.integer64(3) < 3.5` is FALSE). Why: one rule for
  decimal partition values, decimal statistics and 64-bit values, which a
  double rounds.
- *A decimal statistic of precision above 15 is never a bound*, nor one
  that is missing or has more fraction digits than the scale (deltalake
  writes decimal statistics through an f64); the file is kept.
- *Other types* (`float`, `double`, `boolean`, `date`, `timestamp`,
  `timestamp_ntz`) compare as doubles. A `float` statistic is widened by
  one float step, since its shortest decimal sits up to half a step from
  the float; a timestamp statistic by 1 ms each way, since writers
  truncate it to milliseconds; and a `float` or `double` column may hold
  NaN, which no statistic counts, so `is.na()` and `!(x %in% v)` keep its
  files. A date or timestamp column takes text (`"2024-01-31"`, UTC unless
  an offset is given) as well as a `Date` or `POSIXct`. Text against a
  `float` or `double` column is a `zulake_error_filter`, as against a
  `boolean` one (2026-11-27, #73: R compares a double with text as
  strings, so reading the text as a number gave other rows than
  `subset()`, against D8's claim).
- *Strings* compare in UTF-8 byte order on rows too, whatever the
  session's collation; a string maximum is taken as a prefix the true
  maximum may extend. A maximum ending in U+FFFD is taken as the prefix
  before its trailing U+FFFD characters (2026-11-27, #78: Delta Spark
  ends a truncated maximum with U+FFFD as a tie-breaker, which sorts below
  every supplementary character in UTF-8 byte order, so `x == "<prefix>😀"`
  would otherwise be pruned).
- *Null counts.* A file whose `nullCount` equals `numRecords` holds only
  nulls, and one with `numRecords` 0 nothing; a missing count is
  unknown. On an `integer` column, a null count says no row is `NA` only
  when the file's minimum is known and above -2^31: `qio` reads an int32
  of -2^31 as `NA`, R's integer `NA` (with a warning), which the null
  count does not count, and that `NA` is kept rather than converted
  (2026-11-27, #79: `is.na(i32)` was pruned while `is.na(i32 + 0L)` was
  not; a lossless read is asked of `qio`; fixture `zl-int32-min`). On a column read as a list (`binary`), `is.na()` is `TRUE`
  for a null value (`NULL`), as the null count means it, where base R's
  `is.na()` on a list is `FALSE` (settled 2026-11-26, Stage 8, on a
  design adviser's recommendation: R's answer would contradict the
  null-count pruning and leave no way to select a null binary value).

Settled 2026-11-26 (a correction to Stage 4, on a design adviser's
recommendation): a filter is row-wise by construction (D8), so evaluating
it per file equals evaluating it on the whole table, and `lake_read()`
equals binding `lake_walk()`'s pieces. Values are evaluated once and
inlined; the listed functions are then resolved in base, not the caller's
environment, so a local `nchar` cannot change a filter. A row-evaluated
node must return a logical of exactly one value per row. A row-evaluated
node on partition columns is never used to prune. Two details the
implementation fixes: a value inside a row-evaluated call must have length
1, so it means the same for every row (the right of `%in%` excepted), and
a logical column alone is a row-evaluated node. Row-evaluated comparisons
are R's own (a string `<` there follows the session's collation); only the
pruning subset uses the exact comparator above.

## 7. Types

Delta's types map to what `qio` returns for the Parquet column, so
`zulake` adds no conversion of its own for data. For the log itself:
`long` statistics and versions are doubles, exact below 2^53, or an
`integer64` from `bit64` if asked (the `int64` argument, as in `qio`).
`timestamp` is `POSIXct` in UTC. `timestamp_ntz` is `POSIXct` with
`tzone = "UTC"`, and `lake_schema()` marks the column as zone-less.
`decimal` statistics stay as their JSON text, since a double would round
them (D10). Integers past 2^53 - 1 cross `zujson` as marked strings; a
string of the log that itself starts with the mark is given a second one,
and right after parsing a marked number becomes a classed object, so no
string is ever read as a number, and a failure of the scan that marks
them is a corrupt log, never digits left to round (2026-11-27, #56, #57). Data columns zulake does not return (nested ones, D14) are handled so that none is lost
silently (D7): with `columns = NULL` the readable columns are returned and
each unreadable one is named in a classed warning,
`zulake_warning_column_skipped` (fields `column`, `reason`); a column named
in `columns` (or used in `filter`) that cannot be returned is a classed
error, `zulake_error_column_unreadable`, with the same fields. They are
found from each file's `qio::read_plan()` and from the schema, never by
letting `qio` drop them (settled 2026-11-26, Stage 4, maintainer's
direction).

A `decimal(p, s)` data or partition column is a double when p <= 15,
where a double holds it exactly; a wider one is a column `qio` cannot
return (D10, D14) until `qio` 0.2.0 (`reason = "decimal precision <p> >
15"`). zulake muffles `qio`'s decimal-as-double message only when every
decimal column it names is that narrow: by the `precision` of each column in
the `qio_message_decimal_double` condition that `qio` signals from
[pedrobtz/qio#75](https://github.com/pedrobtz/qio/pull/75) on, and, for an
older `qio` whose message is plain text, only when zulake vetted every
decimal column of the read beforehand (2026-11-26). With `qio` 0.2.0 decimals become exact character, and the row
filter must then use the exact comparator (§6) on them: a recorded future
breaking type change for p <= 15 (settled 2026-11-26, Stage 4).

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
- **Example table (2026-11-26, Stage 7).** The README, the Get started
  vignette and every example open `inst/extdata/orders/`, a copy of a new
  fixture `zl-orders` that `tools/fixtures/generate.py` writes with
  `deltalake` 1.7.0 like the other `zl-*` tables (zulake's own data, MIT,
  so no licence change) and `pack.py` copies, with `deltalake`'s answers in
  `answers/` like any fixture. Orders (`order_id` long, `customer` string,
  `amount` double, `order_date` date, `region` string) partitioned by
  `region`; five versions: create, two appends, a row delete that rewrites
  a file, and an append with an application transaction and custom commit
  metadata; no checkpoint, nested, decimal or timestamp column, or
  deletion vector. Data files are renamed `region=<r>/part-<n>.parquet` so
  every path stays under the tarball's 100 bytes, and in-commit timestamps
  (writer feature, reader version 1) are on from version 0 at fixed days,
  because an installed package's files carry the install time; the build
  is deterministic, so `oracle.yaml` rebuilds it. `test-extdata.R` checks
  the copy is the fixture and equals the answers. Why: a table built for
  the documentation shows each function on real output in a few kilobytes,
  and none of the copied `delta-rs` tables is both small and short-pathed
  with times that survive installation.
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
  (D7, Q7). Since Stage 3: `count()` sums the `numRecords` it has, so a
  table without statistics counts 0, where `lake_count()` is `NA` with a
  warning (§5); `get_add_actions()` keys statistics by physical name under
  column mapping, `lake_files()` by logical name; and it drops a
  `decimal(38, 18)` statistic written as a double (`zl-types`), which
  `lake_files()` keeps as its text. Since Stage 4, full reads differ only
  where `qio` 0.1.1 documents a loss, each with `qio`'s own warning or
  zulake's: an `int32` of -2^31 reads as `NA`, a 64-bit value past 2^53
  (as a double) or -2^63 (as `integer64`) as `NA`, a decimal as the
  nearest double, a `float` as the double of its float; and the nested
  and `decimal(38, 18)` columns of `zl-types` are left out (§7). Since
  Stage 5 the deletion-vector and `name`-mode column-mapping fixtures are
  read and compared too, and `deletion_vectors()`' selection vectors are
  compared as `which(!selection_vector) - 1` (D12).
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
    request gets its own cassette until that is fixed. One deliberate
    difference (Stage 6): `deltalake` 1.7.0 lists `_delta_log/`
    recursively on an object store, finds
    `_delta_log/.tmp/00000000000000000005.json` in `simple_table` and then
    opens no version but the latest ("No table version found"), where it
    opens every version from local disk; zulake lists the directory alone,
    as the protocol's log is, so those versions are compared with zulake's
    local answers only.
  - *Live.* A suite against a real ADLS Gen2 account, run only when
    `ZULAKE_AZURE_URI` and a token are set, by `azure-live.yaml` on
    dispatch or by the maintainer locally; it never runs on CRAN.

  Azurite URLs are path-style (`https://127.0.0.1:10000/devstoreaccount1/`),
  so tests reach it through an internal option, `zulake.azure_endpoint`;
  the public API still refuses other schemes (D3). A second internal
  option, `zulake.azure_client` (settled in Stage 6, 2026-11-26), is the
  `zuhttp` client requests go out with: a `zu_mock_transport()` fake, a
  cassette, or a client that trusts Azurite's CA. Why: `zuhttp` has no
  process-wide trust setting, and the fake and the cassettes replace the
  transport, which only a client carries. Cassettes go through a router
  that sends a request with `Range` to a cassette of its own,
  `<name>-range-<from>-<to>` (pedrobtz/zuhttp#353), and are recorded with
  a fixed test token, so the suite can search every cassette file for
  it.
- **Filters.** A property test: for random filters over the fixtures,
  `lake_read(filter = f)` equals reading everything and subsetting in R.
  One deliberate difference: `is.na()` of a list column (§6, *Null
  counts*), which the property test does not draw and `test-filter.R`
  checks against `vapply(x, is.null, NA)`.

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
- **D7 amendment (2026-11-26).** A reader feature is accepted only when
  the protocol's reader requirements for it are implemented, or are
  empty. `vacuumProtocolCheck` is accepted on the second ground: "readers
  don't need to understand or change anything new; they just need to
  acknowledge the feature exists" (PROTOCOL.md at `483d55e`).
  `typeWidening`, `variantType`, `variantShredding` and their `-preview`
  names stay refused, because each obliges the reader to convert or
  decode data. `writerFeatures` is never a reason to refuse (replay reads
  it for in-commit timestamps; reworded 2026-11-26, Stage 4).
- **D7 amendment (2026-11-27, #58).** A `delta.columnMapping.mode` other
  than `none` on a table whose protocol does not declare column mapping
  for readers (reader version 1, or 3 without the reader feature) is
  refused as `columnMapping`, as `deltalake` 1.7.0 refuses it: the table
  breaks the protocol, and reading it by logical names returns `NA` for
  every value of the mapped columns.
- **D8 (reworded 2026-11-26).** Filters are R expressions, not
  `deltalake`'s DNF tuples. The pruning subset and the row-wise function
  list are fixed and documented; a call outside both is refused, never
  evaluated per file, because a per-file result would be silently
  different from the table's (D7). Was: "anything outside it only filters
  rows".
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
- **D12 (2026-11-26; `files` settled in Stage 5).** `files` is `NULL` or
  live files' `path`s or `uri`s as `lake_files()` gives them (another is a
  `zulake_error_argument`); rows follow `lake_files()`' order, `offset` is
  `NA` for an inline vector, and the counts are doubles.
  `lake_deletion_vectors(tbl, files = NULL,
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
- **D14 (2026-11-26; checkpoints done 2026-11-26, Stage 2b).** Checkpoints
  and sidecars are read by `qio`, and 0.1.0 waits for a `qio` that reads
  structs, maps and lists of repetition level 1 (pedrobtz/qio#73). That
  `qio` is 0.1.2.9000 (pedrobtz/qio#76, heading to 0.2.0): `Imports: qio
  (>= 0.1.2.9000)` with `Remotes:` until it is on CRAN, and replay starts
  from the latest checkpoint (§4.2). Data files are still read flat:
  nested data columns are left out with a classed warning naming each, or
  a classed error when the caller named one in `columns` (§7, D7). Kept
  for 0.1.0 (Stage 2b): the stage is about the log, a nested data column
  returned as qio's shapes is an API of its own (struct masks, map data
  frames) that `lake_read()` should not take on unreviewed, and leaving
  them out is never silent. Why: carquet already decodes the leaf streams
  and nested assembly is `qio`'s by its own design, while a commits-only
  0.1.0 would refuse most Databricks tables, whose log cleanup removes old
  commits. D1 stands.
- **D13 (2026-11-26; settled 2026-11-26 by the Stage 6 spike).** Azurite
  over HTTPS with `--oauth basic` is the CI stand-in for Azure; a live ADLS
  Gen2 run is the release gate (§11, criterion 4b). Why: no storage account
  or token is available yet, and Azurite is an independent implementation
  of the Blob REST API. The spike (Azurite 3.35.0, Node 22, a CA and
  server certificate made with `openssl`, `zuhttp` 0.1.0 trusting the CA
  through `zu_tls(ca_extra =)`) confirmed it: with an unsigned JWT
  (`aud` `https://storage.azure.com`, `iss`
  `https://sts.windows.net/<tenant>/`, `exp` in the future) and
  `x-ms-version: 2023-11-03`, Create Container, Put Blob, `List Blobs` with
  `prefix`, `maxresults` and `marker` (two pages), a ranged `Get Blob`
  (`206`, `Content-Range: bytes 6-10/13`) and Get Blob Properties (`HEAD`,
  `404` for a missing blob) all succeeded, and an expired token, a wrong
  audience, a wrong issuer and a non-JWT were each refused. One difference
  from Azure: Azurite refuses a bad token with `403 AuthenticationFailed`,
  where Azure answers `401` (`InvalidAuthenticationInfo`) for an expired
  or invalid token, so the `401` retry of D4 is tested with the request
  fake, and the emulator suite tests the refusal. `deltalake` 1.7.0 reads
  the same containers with the same token (`azure_storage_endpoint`,
  `bearer_token`, `allow_invalid_certificates`), so it is the emulator
  oracle too.

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
- **Q5.** Settled 2026-11-26 as D13: yes, Azurite over HTTPS with
  `--oauth basic`, confirmed by the spike at the start of Stage 6.
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

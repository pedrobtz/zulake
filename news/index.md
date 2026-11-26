# Changelog

## zulake 0.0.0.9000

- [`lake_open()`](https://pedrobtz.github.io/zulake/reference/lake_open.md)
  opens a Delta Lake table on local disk at its latest version, at a
  `version` or at a `timestamp`, replaying its log from commit 0 as the
  Delta protocol prescribes: JSON commits, log compaction files, and the
  reconciliation of `add`, `remove`, `metaData`, `protocol`, `txn` and
  `domainMetadata` actions.
  [`lake_load()`](https://pedrobtz.github.io/zulake/reference/lake_open.md)
  builds another snapshot of the same table,
  [`lake_version()`](https://pedrobtz.github.io/zulake/reference/lake_open.md)
  gives a snapshot’s version, and
  [`lake_is_table()`](https://pedrobtz.github.io/zulake/reference/lake_is_table.md)
  says whether a location holds a table.
- A table that needs a reader feature zulake does not support
  (`columnMapping` in `id` mode, `catalogManaged`, `typeWidening`,
  `variantType`, `variantShredding`, or any feature it does not know) is
  refused with a `zulake_error_unsupported_feature` that names the
  feature, before any data file is read. Its `protocol` field holds the
  table’s protocol as
  [`lake_protocol()`](https://pedrobtz.github.io/zulake/reference/lake_versions.md)
  gives it. `vacuumProtocolCheck`, which asks readers only to
  acknowledge it, is read, and writer features are never a reason to
  refuse.
- Inspection, every function returning a base data frame from the log
  alone:
  [`lake_versions()`](https://pedrobtz.github.io/zulake/reference/lake_versions.md),
  [`lake_history()`](https://pedrobtz.github.io/zulake/reference/lake_versions.md),
  [`lake_metadata()`](https://pedrobtz.github.io/zulake/reference/lake_versions.md),
  [`lake_schema()`](https://pedrobtz.github.io/zulake/reference/lake_versions.md),
  [`lake_partition_columns()`](https://pedrobtz.github.io/zulake/reference/lake_versions.md),
  [`lake_properties()`](https://pedrobtz.github.io/zulake/reference/lake_versions.md),
  [`lake_protocol()`](https://pedrobtz.github.io/zulake/reference/lake_versions.md)
  and
  [`lake_summary()`](https://pedrobtz.github.io/zulake/reference/lake_versions.md)
  describe the table;
  [`lake_files()`](https://pedrobtz.github.io/zulake/reference/lake_files.md),
  [`lake_partitions()`](https://pedrobtz.github.io/zulake/reference/lake_files.md),
  [`lake_removed()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
  and
  [`lake_count()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
  its files;
  [`lake_log()`](https://pedrobtz.github.io/zulake/reference/lake_log.md),
  [`lake_actions()`](https://pedrobtz.github.io/zulake/reference/lake_log.md),
  [`lake_changes()`](https://pedrobtz.github.io/zulake/reference/lake_log.md),
  [`lake_transactions()`](https://pedrobtz.github.io/zulake/reference/lake_log.md),
  [`lake_domains()`](https://pedrobtz.github.io/zulake/reference/lake_log.md)
  and
  [`lake_checkpoints()`](https://pedrobtz.github.io/zulake/reference/lake_log.md)
  the log itself. A snapshot prints a short summary.
- `lake_files(filter =)` and `lake_partitions(filter =)` keep the files
  a filter on partition columns can match; an expression outside the
  pruning subset is a `zulake_error_filter`.
- [`lake_count()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
  is `NA`, with a `zulake_warning_count_unknown` warning, when a live
  file has no `numRecords` statistic, never a partial sum.
- 64-bit values from the log are doubles exact up to 2^53 - 1 and a
  `zulake_error_int64` beyond, or exact
  [`bit64::integer64`](https://bit64.r-lib.org/reference/bit64-package.html)
  values with `int64 = "integer64"`; `decimal` statistics are kept as
  their JSON text.
- Every error is a classed condition inheriting from `zulake_error`; a
  corrupt log (a commit that is not JSON, a partition value of the wrong
  type) is a `zulake_error_corrupt_log`.
- Checkpoints: replay starts from the latest whole checkpoint at or
  before the version, classic, multi-part or V2 (in JSON or Parquet,
  with its sidecars), read through qio (now \>= 0.1.2.9000, which reads
  nested Parquet), so tables whose early commits were cleaned up open. A
  stale `_last_checkpoint` changes nothing; one naming a checkpoint the
  log does not hold whole is a `zulake_error_corrupt_log`. A checkpoint
  that cannot be read is passed over for an earlier one or the commits;
  `zulake_error_checkpoint_unreadable` is left for a version that needs
  it when commit 0 is gone. A version older than the earliest checkpoint
  whose commits were removed is a `zulake_error_version`. Statistics
  come from the `stats` JSON, as in a commit; `stats_parsed` is not
  read.
- [`lake_read()`](https://pedrobtz.github.io/zulake/reference/lake_read.md)
  returns a snapshot’s rows and
  [`lake_walk()`](https://pedrobtz.github.io/zulake/reference/lake_read.md)
  calls a function on each file’s rows, reading the data files with qio
  (now imported) and adding partition columns from the log. A `filter`
  prunes files by partition values and statistics (minimum, maximum,
  null and record counts) before any is read, then filters rows.
  Comparisons in the subset are exact: `long`, integer and `decimal`
  columns digit by digit (a double with no exact 15-digit form is a
  `zulake_error_filter` asking for the value as text), strings in UTF-8
  byte order whatever the collation. `lake_files(filter =)` and
  `lake_partitions(filter =)` now use the statistics too.
- Columns qio cannot return (nested columns, and decimals of precision
  above 15, which a double cannot hold) are left out of a read with a
  `zulake_warning_column_skipped` warning naming each, or are a
  `zulake_error_column_unreadable` error when named in `columns` or used
  in `filter`. A decimal of precision 15 or less is a double.
- Deletion vectors:
  [`lake_read()`](https://pedrobtz.github.io/zulake/reference/lake_read.md)
  and
  [`lake_walk()`](https://pedrobtz.github.io/zulake/reference/lake_read.md)
  never return the rows a deletion vector marks, inline (Z85) or in a
  file at a relative or absolute path, with each vector’s CRC-32
  checked.
  [`lake_deletion_vectors()`](https://pedrobtz.github.io/zulake/reference/lake_deletion_vectors.md)
  lists each live file’s descriptor and, with `rows = TRUE`, the 0-based
  positions of its deleted rows. The rows need the suggested zuroar
  package (installed with `pak::pak("pedrobtz/zuroar")`); without it
  such a read is a `zulake_error_missing_package` naming it, while
  [`lake_count()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
  and `lake_deletion_vectors(rows = FALSE)` still work. A vector that
  does not agree with its descriptor (checksum, magic number, size, row
  count) is a `zulake_error_corrupt_log`, and no rows are returned.
- Tables with column mapping in `name` mode are read, by physical column
  names in the files and logical names in the result; `timestamp_ntz`
  columns are `POSIXct` in UTC.
- `lake_count(footers = TRUE)` reads the row count of each file without
  a `numRecords` statistic from its Parquet footer.
- A `long` statistic in
  [`lake_files()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
  that the `int64` mode cannot hold (such as -2^63) is now `NA` with a
  `zulake_warning_int64` warning, once per column, instead of an error;
  its digits stay in `action`.
- A filter is now row-wise by construction. Besides the pruning subset
  it may apply a fixed list of row-wise functions to columns
  (arithmetic, [`abs()`](https://rdrr.io/r/base/MathFun.html),
  [`round()`](https://rdrr.io/r/base/Round.html),
  [`nchar()`](https://rdrr.io/r/base/nchar.html),
  [`substr()`](https://rdrr.io/r/base/substr.html),
  [`grepl()`](https://rdrr.io/r/base/grep.html),
  [`xor()`](https://rdrr.io/r/base/Logic.html),
  [`as.numeric()`](https://rdrr.io/r/base/numeric.html) and others,
  listed in
  [`?lake_read`](https://pedrobtz.github.io/zulake/reference/lake_read.md))
  and compare two columns; these filter rows after reading and never
  prune, and
  [`lake_files()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
  and
  [`lake_partitions()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
  refuse them. Any other call with a column inside it (`max(x)`,
  `mean(x)`, `rank(x)`, `duplicated(x)`, `%in%` with a column on the
  right, a function of your own) is a `zulake_error_filter` in every
  function, so a filter’s rows never depend on how the table is split
  into files. The functions are base R’s, whatever the caller defines.
- Fixed: on Windows, time travel by timestamp could open the version
  before a commit whose file time is a whole millisecond, at exactly
  that millisecond, because R reads Windows file times up to about 1 µs
  low. File times are now rounded to 10 µs before they are truncated to
  milliseconds.
- Tables on Azure: every function now reads a table given as
  `abfss://<container>@<account>.dfs.core.windows.net/<path>`,
  `https://<account>.dfs.core.windows.net/<container>/<path>` or
  `https://<account>.blob.core.windows.net/<container>/<path>`, through
  the Blob service API, which serves Blob Storage and Data Lake Storage
  Gen2 alike. `credentials` is a function returning a bearer token; it
  is called before the first request and once more after a `401`, and
  the token is never kept in the snapshot, printed or put in an error. A
  refused token is a `zulake_error_auth`, other Azure failures a
  `zulake_error_storage` with the HTTP `status` and Azure’s error
  `code`. Other schemes, and an Azure URI with a query string such as a
  SAS, are a `zulake_error_uri`. Requests go through `zuhttp`, now
  imported.
- The package ships a small example table, orders partitioned by region
  in five versions, at
  `system.file("extdata", "orders", package = "zulake")`. The README,
  the Get started vignette
  ([`vignette("zulake")`](https://pedrobtz.github.io/zulake/articles/zulake.md)),
  now evaluated, and every help page’s examples run on it.

# zulake 0.0.0.9000

* `lake_open()` opens a Delta Lake table on local disk at its latest
  version, at a `version` or at a `timestamp`, replaying its log from
  commit 0 as the Delta protocol prescribes: JSON commits, log compaction
  files, and the reconciliation of `add`, `remove`, `metaData`,
  `protocol`, `txn` and `domainMetadata` actions. `lake_load()` builds
  another snapshot of the same table, `lake_version()` gives a
  snapshot's version, and `lake_is_table()` says whether a location holds
  a table.
* A table that needs a reader feature zulake does not support
  (`columnMapping` in `id` mode, `catalogManaged`, `typeWidening`,
  `variantType`, `variantShredding`, or any feature it does not know) is
  refused with a `zulake_error_unsupported_feature` that names the
  feature, before any data file is read. Its `protocol` field holds the
  table's protocol as `lake_protocol()` gives it. `vacuumProtocolCheck`,
  which asks readers only to acknowledge it, is read, and writer features
  are never a reason to refuse.
* Inspection, every function returning a base data frame from the log
  alone: `lake_versions()`, `lake_history()`, `lake_metadata()`,
  `lake_schema()`, `lake_partition_columns()`, `lake_properties()`,
  `lake_protocol()` and `lake_summary()` describe the table;
  `lake_files()`, `lake_partitions()`, `lake_removed()` and `lake_count()`
  its files; `lake_log()`, `lake_actions()`, `lake_changes()`,
  `lake_transactions()`, `lake_domains()` and `lake_checkpoints()` the log
  itself. A snapshot prints a short summary.
* `lake_files(filter =)` and `lake_partitions(filter =)` keep the files a
  filter on partition columns can match; an expression outside the
  pruning subset is a `zulake_error_filter`.
* `lake_count()` is `NA`, with a `zulake_warning_count_unknown` warning,
  when a live file has no `numRecords` statistic, never a partial sum.
* 64-bit values from the log are doubles exact up to 2^53 - 1 and a
  `zulake_error_int64` beyond, or exact `bit64::integer64` values with
  `int64 = "integer64"`; `decimal` statistics are kept as their JSON text.
* Every error is a classed condition inheriting from `zulake_error`. A
  log that no longer reaches commit 0 is refused with
  `zulake_error_checkpoint_unreadable` until checkpoints can be read; a
  corrupt log (a commit that is not JSON, a partition value of the wrong
  type) with `zulake_error_corrupt_log`.
* `lake_read()` returns a snapshot's rows and `lake_walk()` calls a
  function on each file's rows, reading the data files with qio (now
  imported) and adding partition columns from the log. A `filter` prunes
  files by partition values and statistics (minimum, maximum, null and
  record counts) before any is read, then filters rows. Comparisons in the subset are
  exact: `long`, integer and `decimal` columns digit by digit (a double
  with no exact 15-digit form is a `zulake_error_filter` asking for the
  value as text), strings in UTF-8 byte order whatever the collation.
  `lake_files(filter =)` and `lake_partitions(filter =)` now use the
  statistics too.
* Columns qio cannot return (nested columns, and decimals of precision
  above 15, which a double cannot hold) are left out of a read with a
  `zulake_warning_column_skipped` warning naming each, or are a
  `zulake_error_column_unreadable` error when named in `columns` or used
  in `filter`. A decimal of precision 15 or less is a double.
* Deletion vectors: `lake_read()` and `lake_walk()` never return the rows
  a deletion vector marks, inline (Z85) or in a file at a relative or
  absolute path, with each vector's CRC-32 checked.
  `lake_deletion_vectors()` lists each live file's descriptor and, with
  `rows = TRUE`, the 0-based positions of its deleted rows. The rows need
  the suggested zuroar package (installed with `pak::pak("pedrobtz/zuroar")`);
  without it such a read is a `zulake_error_missing_package` naming it,
  while `lake_count()` and `lake_deletion_vectors(rows = FALSE)` still
  work. A vector that does not agree with its descriptor (checksum, magic
  number, size, row count) is a `zulake_error_corrupt_log`, and no rows are
  returned.
* Tables with column mapping in `name` mode are read, by physical column
  names in the files and logical names in the result; `timestamp_ntz`
  columns are `POSIXct` in UTC.
* `lake_count(footers = TRUE)` reads the row count of each file without a
  `numRecords` statistic from its Parquet footer.
* A `long` statistic in `lake_files()` that the `int64` mode cannot hold
  (such as -2^63) is now `NA` with a `zulake_warning_int64` warning, once
  per column, instead of an error; its digits stay in `action`.
* A filter is now row-wise by construction. Besides the pruning subset it
  may apply a fixed list of row-wise functions to columns (arithmetic,
  `abs()`, `round()`, `nchar()`, `substr()`, `grepl()`, `xor()`,
  `as.numeric()` and others, listed in `?lake_read`) and compare two
  columns; these filter rows after reading and never prune, and
  `lake_files()` and `lake_partitions()` refuse them. Any other call with a
  column inside it (`max(x)`, `mean(x)`, `rank(x)`, `duplicated(x)`, `%in%`
  with a column on the right, a function of your own) is a
  `zulake_error_filter` in every function, so a filter's rows never depend
  on how the table is split into files. The functions are base R's, whatever
  the caller defines.
* Fixed: on Windows, time travel by timestamp could open the version before
  a commit whose file time is a whole millisecond, at exactly that
  millisecond, because R reads Windows file times up to about 1 µs low.
  File times are now rounded to 10 µs before they are truncated to
  milliseconds.
* Tables on Azure: every function now reads a table given as
  `abfss://<container>@<account>.dfs.core.windows.net/<path>`,
  `https://<account>.dfs.core.windows.net/<container>/<path>` or
  `https://<account>.blob.core.windows.net/<container>/<path>`, through
  the Blob service API, which serves Blob Storage and Data Lake Storage
  Gen2 alike. `credentials` is a function returning a bearer token; it is
  called before the first request and once more after a `401`, and the
  token is never kept in the snapshot, printed or put in an error. A
  refused token is a `zulake_error_auth`, other Azure failures a
  `zulake_error_storage` with the HTTP `status` and Azure's error `code`.
  Other schemes, and an Azure URI with a query string such as a SAS, are a
  `zulake_error_uri`. Requests go through `zuhttp`, now imported.

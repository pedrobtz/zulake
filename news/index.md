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
- Every error is a classed condition inheriting from `zulake_error`. A
  log that no longer reaches commit 0 is refused with
  `zulake_error_checkpoint_unreadable` until checkpoints can be read; a
  corrupt log (a commit that is not JSON, a partition value of the wrong
  type) with `zulake_error_corrupt_log`.
- [`lake_read()`](https://pedrobtz.github.io/zulake/reference/lake_read.md)
  returns a snapshot’s rows and
  [`lake_walk()`](https://pedrobtz.github.io/zulake/reference/lake_read.md)
  calls a function on each file’s rows, reading the data files with qio
  (now imported) and adding partition columns from the log. A `filter`
  prunes files by partition values and statistics (minimum, maximum,
  null and record counts) before any is read, then filters rows;
  anything outside the pruning subset only filters rows. Comparisons in
  the subset are exact: `long`, integer and `decimal` columns digit by
  digit (a double with no exact 15-digit form is a `zulake_error_filter`
  asking for the value as text), strings in UTF-8 byte order whatever
  the collation. `lake_files(filter =)` and `lake_partitions(filter =)`
  now use the statistics too.
- Columns qio cannot return (nested columns, and decimals of precision
  above 15, which a double cannot hold) are left out of a read with a
  `zulake_warning_column_skipped` warning naming each, or are a
  `zulake_error_column_unreadable` error when named in `columns` or used
  in `filter`. A decimal of precision 15 or less is a double.
- Reading a table with deletion vectors or column mapping is refused
  with `zulake_error_unsupported_feature` until a later version applies
  them, so a read never returns deleted rows.
- `lake_count(footers = TRUE)` reads the row count of each file without
  a `numRecords` statistic from its Parquet footer.
- A `long` statistic in
  [`lake_files()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
  that the `int64` mode cannot hold (such as -2^63) is now `NA` with a
  `zulake_warning_int64` warning, once per column, instead of an error;
  its digits stay in `action`.

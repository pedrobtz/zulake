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

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

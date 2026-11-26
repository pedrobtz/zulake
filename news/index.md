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
  (`columnMapping` in `id` mode, `catalogManaged`, or any feature it
  does not know) is refused with a `zulake_error_unsupported_feature`
  that names the feature, before any data file is read.
- Every error is a classed condition inheriting from `zulake_error`. A
  log that no longer reaches commit 0 is refused with
  `zulake_error_checkpoint_unreadable` until checkpoints can be read; a
  corrupt log (a commit that is not JSON, a partition value of the wrong
  type) with `zulake_error_corrupt_log`.

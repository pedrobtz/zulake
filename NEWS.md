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
* Every error is a classed condition inheriting from `zulake_error`; a
  corrupt log (a commit that is not JSON, a partition value of the wrong
  type) is a `zulake_error_corrupt_log`.
* Checkpoints: replay starts from the latest whole checkpoint at or before
  the version, classic, multi-part or V2 (in JSON or Parquet, with its
  sidecars), read through qio (now >= 0.1.2.9000, which reads nested
  Parquet), so tables whose early commits were cleaned up open. A stale
  `_last_checkpoint` changes nothing; one naming a checkpoint the log does
  not hold whole is a `zulake_error_corrupt_log`. A checkpoint that cannot
  be read is passed over for an earlier one or the commits;
  `zulake_error_checkpoint_unreadable` is left for a version that needs
  it when commit 0 is gone. A version older than the earliest checkpoint
  whose commits were removed is a `zulake_error_version`. Statistics come
  from the `stats` JSON, as in a commit; `stats_parsed` is not read.
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
* The package ships a small example table, orders partitioned by region in
  five versions, at `system.file("extdata", "orders", package = "zulake")`.
  The README, the Get started vignette (`vignette("zulake")`), now
  evaluated, and every help page's examples run on it.
* zulake needs R 3.5.0 or later, as `qio` and `zuhttp` do; the test
  cassettes are saved in R's serialization format 3 (#37).
* Fixed: a snapshot saved in one R session and restored in another could
  send the other session's bearer token to the saved table's account,
  because credential handles were numbered from 1 in every session. Handle
  ids now start with a random per-session nonce, and a handle reaches only
  the entry made for its own table; a restored snapshot is a
  `zulake_error_auth` asking for `lake_open()` again (#43).
* Fixed: a List Blobs answer whose markers cycle (A, B, A, ...) made
  `lake_open()` send requests forever. Any marker seen before is now a
  `zulake_error_storage` (#45). `ContainerNotFound` after the first page
  is a `zulake_error_storage` too, instead of ending the listing and
  opening an older version (#46).
* Fixed: `credentials()` returning `"Bearer "` sent an empty token, and
  `"bearer x"` was sent as `Bearer bearer x`. The prefix is dropped in any
  case before the token is checked, and a token with a space is refused
  (#47).
* Fixed: a `%00`, or bytes that are not UTF-8, in a log path, an Azure URI
  or an encoded List Blobs name, and a NUL byte in a List Blobs answer,
  gave base R errors. They are a `zulake_error_corrupt_log`,
  `zulake_error_uri` or `zulake_error_storage` (#49).
* Fixed: `abfss://user:password@<account>...` was taken as a container
  named `user:password`, and the refusal quoted it and kept the URI in the
  condition; it is now refused as user information without either (#48).
  An Azure URI with an empty path segment (`.../lake//t`) is refused, as
  the design says, instead of opening `t` (#61).
* Fixed: the log of a table on Azure naming a local path or a `file:` URI
  (a data file or a deletion vector) was read from the reader's own disk.
  A table's files now stay on its own storage: such a path is a
  `zulake_error_uri` (#44).
* Fixed: replay kept live files under R variable names, so a key past
  10000 bytes (an inline deletion vector of a few thousand rows) stopped
  `lake_open()` with a base R error, and in a session whose encoding is not
  UTF-8 two distinct non-ASCII paths could be taken for one file. Keys are
  now kept so that neither can happen (#50).
* Fixed: commit times taken from file modification times are made
  increasing before time travel, as `deltalake` and Delta's history make
  them (a commit not after the previous one counts as 1 ms after it), so
  a copied table whose file times go back opens the version `deltalake`
  opens; `lake_versions()`, `lake_history()` and a snapshot's timestamp
  report the same times (#52). Timestamp travel on a log of checkpoints
  alone is a `zulake_error_version` instead of a warning and a false
  corrupt-log error (#51).
* Fixed: date and time text (partition values, statistics, filter
  literals) is checked by one parser with calendar, hour, minute, second
  and offset ranges, so `"2024-02-30"` is refused when the table is opened
  rather than later, and `"2024-01-01 25:61:61"` or a filter on
  `"... 99:99:99"` is refused instead of moved to another day (#53). A time
  is now the same double qio reads for those microseconds, so a filter on
  a time within seconds of 1970-01-01 finds its rows (#54).
* Fixed: `lake_partitions()` merged distinct partition values (doubles
  equal to 15 digits, `0` and `-0`, `NaN` and null), because it compared
  them as printed text. Rows are now distinct on the log's own values, as
  `deltalake`'s are, and `long` partitions sort by value with
  `int64 = "integer64"` too (#55).
* Fixed: a string in the log that starts with U+001E (a statistic, a
  partition value, a `commitInfo` field) was taken for a 64-bit number,
  so `lake_files()` showed a number and a filter pruned the file holding
  the value (#56). A commit with a very long string before a number past
  2^53 left that number to round, with only a base R warning; the scan is
  now linear, and a failure of it is a `zulake_error_corrupt_log` (#57).
* Fixed: a table setting `delta.columnMapping.mode` without declaring
  column mapping in its protocol was read by logical names, returning
  `NA` for every value. It is now refused with a
  `zulake_error_unsupported_feature` naming `columnMapping`, as `deltalake`
  refuses it (#58).

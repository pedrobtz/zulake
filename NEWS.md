# zulake 0.0.0.9000

* `lake_open()` opens a Delta Lake table on local disk or on Azure at its
  latest version, at a `version` or at a `timestamp`, replaying its log
  from the latest checkpoint (or commit 0) as the Delta protocol
  prescribes: JSON commits, log compaction files, and the reconciliation
  of `add`, `remove`, `metaData`,
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
* zulake needs R 3.5.0 or later, as `qio` and `zuhttp` do (#37). The test
  cassettes are saved in R's serialization format 2, so that `R CMD build`
  adds and announces no dependency of its own (#65).
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
* Fixed: a deletion vector of more rows than its file's `numRecords`, or a
  negative `numRecords`, gave negative counts in `lake_count()` and
  `lake_summary()`; it is now a `zulake_error_corrupt_log` there and in
  `lake_files()` (#59).
* Fixed: `lake_history(limit =)` given an `integer64` read its bits as a
  double (`limit = bit64::as.integer64(2)` gave no rows). Every whole-number
  argument now takes an `integer64` at its value, and refuses one past
  2^53 - 1 with a `zulake_error_argument` (#60).
* Changed: a file or deletion vector the log names by an absolute Azure
  URI on another account or container than the table's is now a
  `zulake_error_uri`, refused before any request, so a log cannot send the
  table's token to an account of its choosing (#76).
* Changed: in a table that maps columns in `name` mode, a field without a
  `delta.columnMapping.physicalName` is now a `zulake_error_corrupt_log`
  naming the field, instead of being read by its logical name, which after
  a rename could be another column's data (#77).
* Fixed: a string maximum ending in U+FFFD, the tie-breaker Delta Spark
  appends to a truncated maximum, is now taken as the prefix before it, so
  a filter on a value with a character above U+FFFD (an emoji) no longer
  prunes the file that holds it (#78).
* Changed: a text literal compared with a `float` or `double` column
  (`amount > "100"`) is now a `zulake_error_filter`, as with a `boolean`
  column; it was read as a number, where R compares the two as strings
  (#73).
* Changed: on R before 4.3.0, `as.character()`, `substr()`, `toupper()`,
  `tolower()` and `grepl()` of a timestamp column in a filter are a
  `zulake_error_filter`, since there a time's text depends on the other
  rows of its file (#74).
* Fixed: an `integer` value of -2^31, which qio reads as `NA`, was missed
  by `is.na()` and `%in% NA` filters whenever its file's null count was 0;
  such a file is now kept unless its minimum is known and above -2^31, so
  equivalent filters agree. `?lake_read` documents the `NA` (#79).
* `?lake_walk` now says that on Azure every file left after pruning is
  downloaded to `tempdir()` before the first piece and kept for the
  session: a walk reads tables larger than memory, not larger than disk
  (#75).
* Fixed: a log compaction file that cannot be read is passed over for the
  commits it covers, and one named `<x>.<x>.compacted.json` (or with an
  end before its start), which the protocol does not define, is no longer
  part of the log, so both tables open as `deltalake` opens them (#69). A
  commit missing while older commits remain is now a
  `zulake_error_corrupt_log` (a hole in the log), not a
  `zulake_error_version` (#70).
* Fixed: a checkpoint that qio reads with a warning other than 64-bit
  loss (an INT32 of -2^31) is reported as unreadable for that reason,
  instead of as needing the bit64 package (#71).
* Fixed: a blob size from Azure (List Blobs, a HEAD, a range's total) that
  is not decimal digits up to 2^53 - 1, such as `Inf`, `0x10`, `1e3` or
  `9007199254740993`, is now a `zulake_error_storage` instead of a number
  read loosely or rounded (#68).
* Fixed: `double` and `float` partition values written as `inf`, `-inf`
  (as `deltalake` writes them) or in any case of `infinity` and `nan` with
  a sign are now read as infinities and NaN, instead of refusing the table
  as a corrupt log (#67).
* Fixed: a relative path in the log with an empty, `.` or `..` segment
  (`../other/part.parquet`) is now a `zulake_error_corrupt_log`, checked
  for every file before any is read, instead of a file read outside the
  table's root (#66).
* Fixed: the download cache is keyed on the blob (account, container and
  name); a copy is written whole or not at all, and one changed on disk is
  downloaded again (#72).
* The download cache belongs to one `lake_open()` call: the snapshot it
  returns and those `lake_load()` makes from it share it, and another
  `lake_open()` of the same table downloads its files again, as delta-rs
  does. It replaces the session-wide cache that served a file only to the
  credentials function that downloaded it (#72).
* Fixed: with `int64 = "integer64"`, a size or record count summed past
  2^63 - 1 is now a `zulake_error_int64` instead of `NA` with a bit64
  warning (#92).
* `filter = q`, with `q` a quoted expression, is now refused with a
  message that says how to pass one (`eval(bquote(...))`), instead of "a
  value must be a vector" (#92).
* Fixed: a JSON object in the log with the same key twice, at any depth
  (in a commit, a log compaction file, a JSON V2 checkpoint or
  `_last_checkpoint`), was read with the key's first value, where
  `deltalake` reads its last, so the two could see different live files.
  It is now a `zulake_error_corrupt_log` whose `file`, `line` and `key`
  fields name it (#102).
* Fixed: a commit that both adds and removes one logical file (the same
  `path` and deletion vector) left the file live, where `deltalake`
  decides by line order. The protocol forbids it, and it is now a
  `zulake_error_corrupt_log` with the `file` and the `path` (#103). A
  file removed and added with a new deletion vector is still an update.
* Fixed: a commit or log compaction file with two adds, or two removes, of
  one path was opened. Two adds of one path under two deletion vectors
  kept both live, so the file was read twice. The protocol allows one add
  and one remove per path in a commit, and such a file is now a
  `zulake_error_corrupt_log` with the `file` and the `path`, whatever the
  deletion vectors (#106).
* Fixed: a `stats` string with the same key twice (a repeated
  `maxValues`, or a column repeated in `minValues`) was read with the
  first value, so a filtered read could prune a file that matches. It is
  now a `zulake_error_corrupt_log` with `file` and `key` where statistics
  are used, and a `schemaString` with a repeated key is one when the
  table is opened (#107).
* Fixed: a MAP in a Parquet checkpoint with the same key twice was read
  with the key's first value. That checkpoint is now passed over for an
  earlier one or commit 0, and is a `zulake_error_checkpoint_unreadable`
  when replay needs it (#108).
* An Azure URI with a port, `:443` included, is still refused, but the
  message now says that the port is the reason, and the
  `zulake_error_uri` has a `port` field, instead of "cannot open
  \"abfss\" URIs" (#92).
* Fixed: a `long` value past 2^53 - 1 in magnitude, which qio reads as
  `NA` with `int64 = "double"`, and -2^63, which it reads as bit64's `NA`
  with `"integer64"`, was missed by `is.na()`, `%in% NA` and `| is.na()`
  filters whenever its file's null count was 0. Such a file is now kept
  unless its bounds are known and inside what the mode holds, as for
  `integer` in #79 (#111).
* Changed: a `decimal` partition value that is not digits with an
  optional sign and fraction (`.5`, `5.`, `-.5`, `1e2`), or that has more
  fraction digits than the scale or more integer digits than the
  precision minus the scale (`12.345` in a `decimal(10,2)`), is now a
  `zulake_error_corrupt_log` naming the value, as `deltalake` refuses it.
  Such a value was read as a number that no filter on the column matched
  (#112).
* Fixed: `is.na()` of a `binary` column is `TRUE` for a null value in
  every part of a filter, as it was alone: `is.na(b) == TRUE`,
  `xor(is.na(b), FALSE)` and the other row-evaluated forms used base R's
  `is.na()`, which is `FALSE` for every element of a list. `b %in% NA` now
  keeps the null values, as `s %in% NA` does for a string column (#113).
* Fixed: filters on `decimal`, `long` and the other exact columns gave no
  rows or failed with a base R error when the session's `LC_NUMERIC` has a
  comma for its decimal point (`Sys.setlocale("LC_NUMERIC",
  "de_DE.UTF-8")`): the numbers zulake writes as text to compare them now
  always use "." (#114).
* Fixed: a statistic whose JSON type is not the column's (`true` as the
  maximum of a `long` column, a number for a `string` column, an array)
  was used as a bound, so a filter could prune a file holding matching
  rows. It is now unknown and the file is kept, as with a missing
  statistic (#115).
* Fixed: a log compaction file over a range in which one path changes its
  deletion vector more than once, which holds two tombstones of that path
  as reconciliation requires, was refused as a corrupt log. In a
  compaction file only two adds, or two removes, of one logical file
  (`(path, deletionVector.uniqueId)`) are refused now; the rule of one
  per path whatever the deletion vector stays for a commit. A compaction
  file these checks refuse is passed over for the commits it covers, as
  an unreadable one is, and is a `zulake_error_corrupt_log` only when
  replay needs it (#117).
* Changed: the schema is checked when a table is opened. A type the
  protocol does not define (`varchar(10)`, `STRING`, `decimal` without
  its precision), a field without a `type`, a field without a
  `name` or with an empty one, two fields of one struct with one name, and
  in `name` column mapping mode two fields with one physical name are a
  `zulake_error_corrupt_log` naming the field. A `variant` or
  `timestamp_ntz` column in a table whose protocol does not declare its
  reader feature is a `zulake_error_unsupported_feature` naming the
  feature. Such schemas opened, and then read whatever the files held,
  read two fields as one column, or failed with a base R error (#120).
* Fixed: a log line holding two actions (`{"add":{...},"remove":{...}}`)
  applied both, where `deltalake` applies one. The protocol stores one
  action per line, so such a line is now a `zulake_error_corrupt_log` with
  the `file` and the `line`, in a commit, a compaction file or a JSON V2
  checkpoint (#121).
* Fixed: a log file whose body ended early, as a server that closes the
  connection without a `Content-Length` sends it, was replayed as if
  whole: on Azure, a commit cut by a line gave other rows with no error.
  Each log file (commits, checkpoints and their parts, V2 sidecars,
  compaction files, `_last_checkpoint`) must now have the size the listing
  gives (for a sidecar, its action's `sizeInBytes`); a difference is a
  `zulake_error_storage` with the `path`, the `size` read and the
  `listed_size`. A checkpoint so cut is passed over for an earlier one or
  the commits, as an unreadable one is (#122).
* Fixed: a column named `a.b` beside a struct `a` with a field `b` failed
  the whole read with qio's unclassed "Ambiguous Parquet column". qio
  selects columns only by dotted path (pedrobtz/qio#78), so such a column
  is now one zulake cannot return: left out with a
  `zulake_warning_column_skipped`, or a `zulake_error_column_unreadable`
  when named in `columns` or used in `filter`, and the other columns read
  (#116).
* Changed: a partition column reads as a data column of its type does. A
  `float` value is rounded through single precision (`1.1` reads as
  1.100000023841858, `1e39` as `Inf`), in `lake_files()` and pruning too;
  an `integer` is an R integer, with -2^31 as `NA` and qio's warning; a
  `binary` value is a list of raw vectors, the UTF-8 bytes of the log's
  text. Times with more than six fraction digits, in partition values and
  statistics, are truncated to the microsecond as `deltalake` does, not
  rounded; a filter literal with a non-zero digit past the microsecond is
  a `zulake_error_filter` (#118).
* Changed: each data file's Parquet type is checked against the schema
  before any row is read. A type the column's Delta type does not read
  (strings in a `long` column, INT64 in an `integer` one, a decimal of
  another scale) is a `zulake_error_corrupt_log` naming the `file` and the
  `column`, with the `type`, `physical_type` and `logical_type`; an INT32
  file of a `long` column is widened to the `long` mapping, as `deltalake`
  upcasts it. A column's R type now follows its Delta type in every file
  (#119).
* Fixed: errors of the read path that were not classed. A data file qio
  cannot open or decode (truncated, empty, not Parquet, a corrupt page) is
  a `zulake_error_storage` whose `path` names it, with qio's message; a
  download cache directory that is a file or read-only is a
  `zulake_error_storage`, without a base warning; a deletion-vector file
  that is not there is "no such file", not a corrupt log; and a listing on
  Azure that names a blob twice is a `zulake_error_storage` (it listed the
  version twice, or failed with a base R error for the latest commit)
  (#123, #124).
* Changed: a `void` column, which the protocol defines as holding only
  nulls, is read: an all-`NA` logical column never read from a file, a
  `void` partition column accepting only null values, and `is.na()` `TRUE`
  on it (#133).
* Changed: two fields of one struct whose names differ only in case (`id`
  and `ID`) are a `zulake_error_corrupt_log`, as the protocol requires
  names unique regardless of case; names are folded in ASCII only, so
  non-ASCII names that differ only in case still open (#134).

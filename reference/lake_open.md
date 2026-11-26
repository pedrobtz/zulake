# Open a table

`lake_open()` builds a snapshot of a Delta Lake table: one version of
it, replayed from the table's own log as the Delta protocol prescribes.
A snapshot never changes; `lake_load()` builds another one of the same
table, at another version or at the version the log now ends at.

## Usage

``` r
lake_open(uri, version = NULL, timestamp = NULL, credentials = NULL)

lake_load(tbl, version = NULL, timestamp = NULL)

lake_version(tbl)
```

## Arguments

- uri:

  Location of the table: the path of its directory, the one that holds
  `_delta_log/`.

- version:

  Version to open, a whole number. `NULL`, the default, is the latest
  version.

- timestamp:

  Open the latest version committed at or before this time, a `POSIXct`.
  The commit time is the commit's in-commit timestamp when the table
  records them, and the commit file's modification time otherwise. A
  time before the first commit opens the first version. Give `version`
  or `timestamp`, not both.

- credentials:

  A function of no arguments returning a bearer token, for tables on
  Azure. Not used for local paths.

- tbl:

  A snapshot, from `lake_open()` or `lake_load()`.

## Value

`lake_open()` and `lake_load()` return a snapshot, an object of class
`zulake_table`. `lake_version()` returns the version a snapshot holds, a
whole number as a double.

Every error is a condition of class `zulake_error`, with a subclass that
says why: `zulake_error_not_table` (no Delta log at `uri`),
`zulake_error_version` (no such version), `zulake_error_corrupt_log` (a
log that breaks the protocol, such as a commit that is not JSON or a
partition value of the wrong type), `zulake_error_checkpoint_unreadable`
and `zulake_error_unsupported_feature`, whose `feature` field names the
feature.

## Details

The snapshot holds the version's protocol, metadata, live files,
tombstones, application transactions and metadata domains. It is checked
before it is returned: a table that needs a reader feature zulake does
not support is refused with an error naming that feature, before any
data file is read, because ignoring a feature returns wrong rows.

In this version zulake reads tables on local disk, replaying the log
from its first commit. A table whose log no longer reaches commit 0
needs a checkpoint, which zulake cannot read yet, and is refused with a
`zulake_error_checkpoint_unreadable` error.

## See also

[`lake_is_table()`](https://pedrobtz.github.io/zulake/reference/lake_is_table.md)
to check a location first.

## Examples

``` r
# A one-file table written by hand, so the example needs nothing else.
path <- tempfile("table")
dir.create(file.path(path, "_delta_log"), recursive = TRUE)
writeLines(c(
  '{"protocol":{"minReaderVersion":1,"minWriterVersion":2}}',
  paste0(
    '{"metaData":{"id":"example","format":{"provider":"parquet","options":{}},',
    '"schemaString":"{\\"type\\":\\"struct\\",\\"fields\\":[{\\"name\\":',
    '\\"id\\",\\"type\\":\\"long\\",\\"nullable\\":true,\\"metadata\\":{}}]}",',
    '"partitionColumns":[],"configuration":{}}}'
  ),
  paste0(
    '{"add":{"path":"part-0.parquet","partitionValues":{},"size":100,',
    '"modificationTime":0,"dataChange":true}}'
  )
), file.path(path, "_delta_log", "00000000000000000000.json"))

lake_is_table(path)
#> [1] TRUE
tbl <- lake_open(path)
lake_version(tbl)
#> [1] 0
tbl0 <- lake_load(tbl, version = 0)

unlink(path, recursive = TRUE)
```

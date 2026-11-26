# The log itself

Functions that return what `_delta_log/` holds, as data frames:

## Usage

``` r
lake_log(tbl)

lake_actions(tbl, version, int64 = c("double", "integer64"))

lake_changes(
  tbl,
  from,
  to = lake_version(tbl),
  int64 = c("double", "integer64")
)

lake_transactions(tbl, int64 = c("double", "integer64"))

lake_domains(tbl)

lake_checkpoints(tbl)
```

## Arguments

- tbl:

  A snapshot, from
  [`lake_open()`](https://pedrobtz.github.io/zulake/reference/lake_open.md).

- version:

  The version of the commit to return, a whole number. Its commit file
  must still be in the log.

- int64:

  How 64-bit integers from the log are returned: `"double"` (the
  default), exact up to 2^53 - 1 and an error of class
  `zulake_error_int64` beyond it, or `"integer64"`, from the bit64
  package, exact from -2^63 + 1 to 2^63 - 1 (bit64 keeps -2^63 for `NA`,
  so that value is an error too). It applies to the columns that hold
  64-bit counts and values; inside an action or `commitInfo` as the log
  writes it, only a number a double cannot hold becomes an integer64.

- from, to:

  The two versions to compare, whole numbers with `from` at most `to`.
  `to` defaults to the snapshot's version.

## Value

`lake_log()`: a data frame `name`, `kind` (`"commit"`, `"checkpoint"`,
`"compaction"`, `"checksum"` or `"last_checkpoint"`), `version` (the
first version of a compaction file, `NA` for `_last_checkpoint`),
`end_version` (compaction files only), `part` and `parts` (multi-part
checkpoints only), `size` and `modification_time`, sorted by name.

`lake_actions()`: a data frame with one row per action: `version`,
`line` (the action's line in the commit file), `type` (`"add"`,
`"remove"`, `"metaData"`, `"protocol"`, `"commitInfo"`, `"txn"`, or any
other name the log uses) and `action`, a list column holding the action
as the log writes it.

`lake_changes()`: a data frame with the columns of
`lake_files(stats = FALSE)` after a first column `change`, `"added"` for
a file live at `to` and not at `from`, `"removed"` for the reverse. A
file is identified by its path and deletion vector, as the protocol
does, so a file given a new deletion vector is removed and added.

`lake_transactions()`: a data frame `app_id`, `version` and
`last_updated` (`POSIXct`, `NA` when the action has none), sorted by
application.

`lake_domains()`: a data frame `domain` and `configuration` (the
domain's configuration string, as the log writes it), sorted by domain.

`lake_checkpoints()`: a data frame `version`, `name`, `type`
(`"classic"`, `"multi-part"` or `"v2"`), `part`, `parts`, `size`,
`modification_time` and `last_checkpoint` (whether `_last_checkpoint`
names this checkpoint's version), sorted by version and name.

## Details

- `lake_log()`: every entry of the `_delta_log/` listing taken when the
  snapshot was opened, including versions after the snapshot's.

- `lake_actions()`: every action of one commit, in file order.

- `lake_changes()`: the files added and removed between two versions.

- `lake_transactions()`: the latest `txn` action of each application.

- `lake_domains()`: the metadata domains in force (`domainMetadata`).

- `lake_checkpoints()`: the checkpoint files in the listing, and which
  one `_last_checkpoint` names.

## See also

[`lake_versions()`](https://pedrobtz.github.io/zulake/reference/lake_versions.md)
for the table's versions and history.

## Examples

``` r
path <- tempfile("table")
dir.create(file.path(path, "_delta_log"), recursive = TRUE)
log <- file.path(path, "_delta_log")
writeLines(c(
  '{"protocol":{"minReaderVersion":1,"minWriterVersion":2}}',
  paste0(
    '{"metaData":{"id":"example","format":{"provider":"parquet","options":{}},',
    '"schemaString":"{\\"type\\":\\"struct\\",\\"fields\\":[{\\"name\\":',
    '\\"id\\",\\"type\\":\\"long\\",\\"nullable\\":true,\\"metadata\\":{}}]}",',
    '"partitionColumns":[],"configuration":{}}}'
  ),
  paste0(
    '{"add":{"path":"a.parquet","partitionValues":{},"size":100,',
    '"modificationTime":0,"dataChange":true}}'
  )
), file.path(log, "00000000000000000000.json"))
writeLines(c(
  '{"txn":{"appId":"loader","version":7}}',
  '{"remove":{"path":"a.parquet","deletionTimestamp":1,"dataChange":true}}',
  paste0(
    '{"add":{"path":"b.parquet","partitionValues":{},"size":120,',
    '"modificationTime":1,"dataChange":true}}'
  )
), file.path(log, "00000000000000000001.json"))

tbl <- lake_open(path)
lake_log(tbl)[c("name", "kind", "version")]
#>                        name   kind version
#> 1 00000000000000000000.json commit       0
#> 2 00000000000000000001.json commit       1
lake_actions(tbl, 1)[c("line", "type")]
#>   line   type
#> 1    1    txn
#> 2    2 remove
#> 3    3    add
lake_changes(tbl, from = 0)[c("change", "path")]
#>    change      path
#> 1   added b.parquet
#> 2 removed a.parquet
lake_transactions(tbl)
#>   app_id version last_updated
#> 1 loader       7         <NA>
lake_domains(tbl)
#> [1] domain        configuration
#> <0 rows> (or 0-length row.names)
lake_checkpoints(tbl)
#> [1] version           name              type              part             
#> [5] parts             size              modification_time last_checkpoint  
#> <0 rows> (or 0-length row.names)

unlink(path, recursive = TRUE)
```

# The table: versions, metadata, schema, protocol

Functions that describe the table a snapshot holds, each from the log
alone; none reads a data file.

## Usage

``` r
lake_versions(tbl)

lake_history(tbl, limit = NULL, int64 = c("double", "integer64"))

lake_metadata(tbl)

lake_schema(tbl)

lake_partition_columns(tbl)

lake_properties(tbl)

lake_protocol(tbl)

lake_summary(tbl, int64 = c("double", "integer64"))
```

## Arguments

- tbl:

  A snapshot, from
  [`lake_open()`](https://pedrobtz.github.io/zulake/reference/lake_open.md).

- limit:

  The number of commits to return, newest first. `NULL`, the default,
  returns all of them.

- int64:

  How 64-bit integers from the log are returned: `"double"` (the
  default), exact up to 2^53 - 1 and an error of class
  `zulake_error_int64` beyond it, or `"integer64"`, from the bit64
  package, exact from -2^63 + 1 to 2^63 - 1 (bit64 keeps -2^63 for `NA`,
  so that value is an error too). It applies to the columns that hold
  64-bit counts and values; inside an action or `commitInfo` as the log
  writes it, only a number a double cannot hold becomes an integer64.

## Value

`lake_versions()`: a data frame `version`, `timestamp` (`POSIXct`, UTC),
oldest first.

`lake_history()`: a data frame `version`, `timestamp` (the commit time),
`operation` and `commit_info`, a list column holding each commit's
`commitInfo` action as the log writes it (`NULL` for a commit without
one), newest first.

`lake_metadata()`: a data frame of one row: `id`, `name`, `description`,
`format_provider`, `format_options` (a list column), `created_time`
(`POSIXct`, or `NA`), `partition_columns` (a list column) and
`configuration` (a list column; see also `lake_properties()`).

`lake_schema()`: a data frame `name`, `type` (the Delta type, such as
`"long"`, `"decimal(10,2)"` or `"timestamp_ntz"`, which is the zone-less
timestamp; `"struct"`, `"array"` or `"map"` for a nested column),
`nullable`, `partition` (whether it is a partition column),
`physical_name` (its name in the data files under column mapping, `NA`
otherwise), `metadata` and `type_detail` (list columns: the column's
metadata, and the nested type as the log writes it, `NULL` for a
primitive one).

`lake_partition_columns()`: a character vector.

`lake_properties()`: a data frame `key`, `value` and `default` (`TRUE`
for a property the table does not set, filled in with the protocol's
default), sorted by key.

`lake_protocol()`: a data frame with one row per requirement: first
`readerVersion` and `writerVersion` with their `version`, then each
feature, with `reader` and `writer` saying which list of the protocol
names it, and `supported`, whether zulake reads a table that needs it.
Writer requirements are always supported: zulake does not write. A
snapshot only exists for a table zulake can read, so every row of a
snapshot's protocol is supported; the `zulake_error_unsupported_feature`
error of a table that is refused carries the same data frame in its
`protocol` field.

`lake_summary()`: a data frame of one row: `version`, `timestamp`,
`files`, `bytes`, `records` (as
[`lake_count()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
counts them, `NA` when a file has no `numRecords`), `deleted_rows` (the
cardinality of the deletion vectors), `files_with_deletion_vectors` and
`files_without_records`.

## Details

- `lake_versions()`: every version up to the snapshot's whose commit is
  still in the log, with its commit time.

- `lake_history()`: the `commitInfo` of those commits, newest first.

- `lake_metadata()`: the table's `metaData` action, in one row.

- `lake_schema()`: one row per top-level column.

- `lake_partition_columns()`: the partition columns, in order.

- `lake_properties()`: the table's configuration, with the defaults the
  protocol states filled in.

- `lake_protocol()`: the reader and writer versions and every feature,
  each marked supported or not.

- `lake_summary()`: one row of totals.

The commit time of a version is the commit's in-commit timestamp when
the table records them, and the commit file's modification time
otherwise, as the protocol prescribes and as `lake_open(timestamp =)`
uses it. File times are made increasing first, as Delta and `deltalake`
make them: a commit whose file time is not after the previous commit's
counts as 1 millisecond after it.

## See also

[`lake_files()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
for the files,
[`lake_actions()`](https://pedrobtz.github.io/zulake/reference/lake_log.md)
for a commit's actions.

## Examples

``` r
# The example table the package ships: orders partitioned by region, five versions.
path <- system.file("extdata", "orders", package = "zulake")
tbl <- lake_open(path)
lake_versions(tbl)
#>   version           timestamp
#> 1       0 2025-01-06 09:00:00
#> 2       1 2025-01-07 09:00:00
#> 3       2 2025-01-08 09:00:00
#> 4       3 2025-01-09 09:00:00
#> 5       4 2025-01-10 09:00:00
lake_history(tbl, limit = 2)[c("version", "timestamp", "operation")]
#>   version           timestamp operation
#> 1       4 2025-01-10 09:00:00     WRITE
#> 2       3 2025-01-09 09:00:00    DELETE
lake_metadata(tbl)[c("name", "description", "created_time")]
#>     name                      description        created_time
#> 1 orders zulake example: orders by region 2025-01-06 09:00:00
lake_schema(tbl)[c("name", "type", "nullable", "partition")]
#>         name   type nullable partition
#> 1   order_id   long     TRUE     FALSE
#> 2   customer string     TRUE     FALSE
#> 3     amount double     TRUE     FALSE
#> 4 order_date   date     TRUE     FALSE
#> 5     region string     TRUE      TRUE
lake_partition_columns(tbl)
#> [1] "region"
props <- lake_properties(tbl)
props[!props$default, ]  # the ones the table sets
#>                              key value default
#> 5 delta.enableInCommitTimestamps  true   FALSE
lake_protocol(tbl)
#>                name reader writer version supported
#> 1     readerVersion   TRUE  FALSE       1      TRUE
#> 2     writerVersion  FALSE   TRUE       7      TRUE
#> 3 inCommitTimestamp  FALSE   TRUE      NA      TRUE
lake_summary(tbl)
#>   version           timestamp files bytes records deleted_rows
#> 1       4 2025-01-10 09:00:00    12 16890      23            0
#>   files_with_deletion_vectors files_without_records
#> 1                           0                     0
```

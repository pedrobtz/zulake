# The files of a snapshot

`lake_files()` lists the snapshot's live files, one row per `add` action
in force, with their partition values, statistics and deletion vector
descriptors. `lake_partitions()` gives the distinct partition values of
those files. `lake_removed()` lists the tombstones (`remove` actions)
still in the log. `lake_count()` counts the snapshot's rows from the log
alone.

## Usage

``` r
lake_files(tbl, filter = NULL, stats = TRUE, int64 = c("double", "integer64"))

lake_partitions(tbl, filter = NULL, int64 = c("double", "integer64"))

lake_removed(tbl, int64 = c("double", "integer64"))

lake_count(tbl, footers = FALSE)
```

## Arguments

- tbl:

  A snapshot, from
  [`lake_open()`](https://pedrobtz.github.io/zulake/reference/lake_open.md)
  or
  [`lake_load()`](https://pedrobtz.github.io/zulake/reference/lake_open.md).

- filter:

  An expression over column names; see Details. `NULL`, the default,
  keeps every file.

- stats:

  Whether to parse the files' statistics into `num_records`,
  `null_count`, `min` and `max`.

- int64:

  How 64-bit integers from the log are returned: `"double"` (the
  default), exact up to 2^53 - 1 and an error of class
  `zulake_error_int64` beyond it, or `"integer64"`, from the bit64
  package, exact from -2^63 + 1 to 2^63 - 1 (bit64 keeps -2^63 for `NA`,
  so that value is an error too). It applies to the columns that hold
  64-bit counts and values; inside an action or `commitInfo` as the log
  writes it, only a number a double cannot hold becomes an integer64.

- footers:

  Whether to read the row count of each live file that has no
  `numRecords` statistic from its Parquet footer, which downloads those
  files. `FALSE`, the default, reads nothing but the log.

## Value

`lake_files()` returns a data frame with one row per live file, sorted
by path: `path` (as the log writes it, relative to the table or
absolute), `uri` (where the file is), `size_bytes`, `modification_time`
(`POSIXct`), `data_change`, `partition` (a list column of named lists of
typed values), `deletion_vector` (a list column: the descriptor, or
`NULL`), then, with `stats = TRUE`, `num_records`, `null_count`, `min`
and `max`, and last `action`, the `add` action as the log holds it.

`lake_partitions()` returns a data frame with one column per partition
column and one row per distinct combination of values among the live
files the filter keeps, distinct as the log writes them (so `"1"` and
`"1.0"` are two rows, as in `deltalake`); a table without partition
columns has none.

`lake_removed()` returns a data frame with one row per tombstone:
`path`, `deletion_timestamp` (`POSIXct`), `data_change`, `size_bytes`,
`partition_values` (a list column of the values as the log writes them),
`deletion_vector` and `action`.

`lake_count()` returns the number of rows, a double: the sum of
`numRecords` over the live files minus the rows their deletion vectors
delete (each descriptor's `cardinality`). When a live file has no
`numRecords` the count is unknown: `NA_real_`, with a warning of class
`zulake_warning_count_unknown` whose `files` field gives the number of
such files, unless `footers = TRUE` reads those files' row counts from
their Parquet footers. It is never a partial sum. A file with a deletion
vector and no `numRecords` breaks the protocol:
`zulake_error_corrupt_log`.

## Details

Partition values are typed by the column's Delta type: `byte` and
`short` as integers, `integer` as doubles (an R integer cannot hold
-2^31), `long` as 64-bit values (see `int64`), `float` and `double` as
doubles, `boolean` as logicals, `date` as `Date`, `timestamp` and
`timestamp_ntz` as `POSIXct` in UTC, and `decimal`, `string` and
`binary` as the text the log holds. A null partition value is `NA`.

Statistics come from each file's `stats` JSON, keyed by column name:
`min` and `max` typed as partition values are, except that a `decimal`
statistic stays its JSON text exactly as the log writes it, since a
double would round it; `null_count` and `num_records` are 64-bit counts.
A `long` minimum or maximum that `int64` cannot hold (past 2^53 - 1 as a
double, or -2^63, which bit64 keeps for `NA`) is `NA`, with a warning of
class `zulake_warning_int64` (fields `value`, `column` and `path`) once
per column; its digits stay in `action`. Statistics are optional in the
protocol, so a file can have none (`NA` and `NULL`).

`filter` is an unevaluated R expression over column names, of
comparisons (`==`, `!=`, `<`, `<=`, `>`, `>=`), `%in%` and
[`is.na()`](https://rdrr.io/r/base/NA.html) joined by `!`, `&` and `|`,
with literals or values from the calling environment. A file is kept
when the filter can be `TRUE` for one of its rows: a comparison on a
partition column is decided by the file's partition value, one on
another column by the file's statistics, and a file without statistics
for that column is kept. Values compare exactly, as
[`lake_read()`](https://pedrobtz.github.io/zulake/reference/lake_read.md)
describes. Anything else, the row-wise functions
[`lake_read()`](https://pedrobtz.github.io/zulake/reference/lake_read.md)
applies to rows included, is refused with a `zulake_error_filter` error,
since there are no rows here to apply it to.

## See also

[`lake_summary()`](https://pedrobtz.github.io/zulake/reference/lake_versions.md)
for the totals in one row,
[`lake_changes()`](https://pedrobtz.github.io/zulake/reference/lake_log.md)
for the files added and removed between two versions.

## Examples

``` r
# The example table the package ships: orders partitioned by region, five versions.
path <- system.file("extdata", "orders", package = "zulake")
tbl <- lake_open(path)
lake_files(tbl)[c("path", "size_bytes", "num_records")]
#>                             path size_bytes num_records
#> 1  region=APAC/part-0001.parquet       1438           3
#> 2  region=APAC/part-0004.parquet       1409           2
#> 3  region=APAC/part-0007.parquet       1412           2
#> 4  region=APAC/part-0011.parquet       1382           1
#> 5    region=EU/part-0002.parquet       1434           3
#> 6    region=EU/part-0005.parquet       1409           2
#> 7    region=EU/part-0008.parquet       1412           2
#> 8    region=EU/part-0012.parquet       1382           1
#> 9    region=US/part-0006.parquet       1409           2
#> 10   region=US/part-0009.parquet       1409           2
#> 11   region=US/part-0010.parquet       1412           2
#> 12   region=US/part-0013.parquet       1382           1
# Partition values and statistics decide which files a filter can match:
lake_files(tbl, filter = region == "EU" & amount > 1000)$path
#> [1] "region=EU/part-0002.parquet" "region=EU/part-0008.parquet"
lake_partitions(tbl)
#>   region
#> 1   APAC
#> 2     EU
#> 3     US
lake_removed(tbl)[c("path", "deletion_timestamp")]
#>                          path  deletion_timestamp
#> 1 region=US/part-0003.parquet 2025-01-09 09:00:00
lake_count(tbl)
#> [1] 23
```

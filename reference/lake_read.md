# Read a table's rows

`lake_read()` returns the rows of a snapshot as a data frame. It prunes
the live files with `filter` first, so that only the files whose rows
could match are read, then reads each one with qio, adds the partition
columns from the log, keeps the rows `filter` is `TRUE` for, and binds
the pieces. `lake_walk()` does the same one file at a time and calls
`FUN` on each piece instead of binding them, for tables larger than
memory.

## Usage

``` r
lake_read(tbl, columns = NULL, filter = NULL, int64 = c("double", "integer64"))

lake_walk(
  tbl,
  FUN,
  columns = NULL,
  filter = NULL,
  int64 = c("double", "integer64")
)
```

## Arguments

- tbl:

  A snapshot, from
  [`lake_open()`](https://pedrobtz.github.io/zulake/reference/lake_open.md).

- columns:

  Columns to return, a character vector of column names, in that order.
  `NULL`, the default, returns every column qio can return.

- filter:

  An expression over column names; see Details. `NULL`, the default,
  keeps every row.

- int64:

  How 64-bit integers reach R, in data and partition columns: `"double"`
  (the default), exact up to 2^53 (qio returns `NA` with a warning past
  it, and a `long` partition value past 2^53 - 1 is an error of class
  `zulake_error_int64`), or `"integer64"` from the bit64 package.

- FUN:

  A function, called with each piece: a data frame of one file's
  matching rows, in the same columns as `lake_read()` returns. Files
  without a matching row are skipped.

## Value

`lake_read()` returns a data frame with one column per column asked for
and one row per matching row, in the order of the files in
[`lake_files()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
and of the rows in each file. `lake_walk()` returns `NULL`, invisibly.

## Details

`filter` is an unevaluated R expression over column names, with values
from the calling environment (a column's name always means the column).
Its pruning subset is comparisons (`==`, `!=`, `<`, `<=`, `>`, `>=`),
`%in%` and [`is.na()`](https://rdrr.io/r/base/NA.html) between a column
and values, joined by `!`, `&` and `|`. That subset rules files out by
their partition values and their statistics (minimum, maximum, null
count and record count). Statistics only decide what is read: the rows
returned are the rows `filter` is `TRUE` for whatever the statistics
say, and a missing statistic only means a file is read.

A filter may also apply these row-wise functions to columns: `+`, `-`,
`*`, `/`, `%%`, `%/%`, `^`,
[`abs()`](https://rdrr.io/r/base/MathFun.html),
[`round()`](https://rdrr.io/r/base/Round.html),
[`floor()`](https://rdrr.io/r/base/Round.html),
[`ceiling()`](https://rdrr.io/r/base/Round.html),
[`sqrt()`](https://rdrr.io/r/base/MathFun.html),
[`exp()`](https://rdrr.io/r/base/Log.html),
[`log()`](https://rdrr.io/r/base/Log.html),
[`nchar()`](https://rdrr.io/r/base/nchar.html),
[`toupper()`](https://rdrr.io/r/base/chartr.html),
[`tolower()`](https://rdrr.io/r/base/chartr.html),
[`substr()`](https://rdrr.io/r/base/substr.html),
[`startsWith()`](https://rdrr.io/r/base/startsWith.html),
[`endsWith()`](https://rdrr.io/r/base/startsWith.html),
[`grepl()`](https://rdrr.io/r/base/grep.html),
[`is.nan()`](https://rdrr.io/r/base/is.finite.html),
[`is.finite()`](https://rdrr.io/r/base/is.finite.html),
[`xor()`](https://rdrr.io/r/base/Logic.html),
[`as.character()`](https://rdrr.io/r/base/character.html),
[`as.numeric()`](https://rdrr.io/r/base/numeric.html) and
[`as.integer()`](https://rdrr.io/r/base/integer.html); and compare two
columns, or use a logical column alone. R evaluates those on the rows
after reading (they never prune), with base R's functions whatever the
caller defines, and each must give one `TRUE`, `FALSE` or `NA` per row.
Any other call with a column inside it, such as `max(x)`, `mean(x)`,
`rank(x)`, `cumsum(x)`, `duplicated(x)`, `x[1]`, `%in%` with a column on
its right, or a function of your own, is an error of class
`zulake_error_filter`: a filter is decided row by row, so the rows it
keeps do not depend on how the table's rows are split into files, and
`lake_read()` equals the pieces of `lake_walk()` bound together. A part
of the filter that names no column is a value, evaluated once where
`lake_read()` is called, and may be any R expression.

Inside the pruning subset, comparisons are exact: a `long`, `integer`,
`short`, `byte` or `decimal` column is compared with the value as
decimal numbers, digit by digit, and a `string` column in UTF-8 byte
order whatever the session's collation, as the table's statistics are. A
value given as text, such as `"12.30"`, is read as that decimal number;
a double that has no exact decimal form of 15 digits (`1/3`,
`0.1 + 0.2`) is an error asking for the value as text. A date or
timestamp column takes a `Date` or `POSIXct`, or text such as
`"2024-01-31"` or `"2024-01-31 12:00:00"` (UTC unless it gives an
offset).

Columns are typed as qio returns them (see
[`qio::read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.html)),
and partition columns as
[`lake_files()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
types them, except that a `decimal` of precision 15 or less, data or
partition, is a double, which holds it exactly. Columns qio cannot
return are not lost silently: nested columns (`struct`, `array`, `map`)
and decimals of precision above 15, until qio reads them. With
`columns = NULL` they are left out, each named in a warning of class
`zulake_warning_column_skipped` (fields `column` and `reason`); named in
`columns` or used in `filter`, such a column is an error of class
`zulake_error_column_unreadable` with the same fields.

Data files are read in place on local disk; other stores download each
file once per session, to the session's temporary directory.

Rows a deletion vector marks as deleted are never returned (see
[`lake_deletion_vectors()`](https://pedrobtz.github.io/zulake/reference/lake_deletion_vectors.md));
reading their vectors needs the zuroar package, and without it a read of
a table with deletion vectors in the files it reads is an error of class
`zulake_error_missing_package`. Every such vector is read and checked
before any data file, so a corrupt one (`zulake_error_corrupt_log`)
returns no rows. A table that maps column names (column mapping in
`name` mode) is read by each column's physical name in the files and
returned with its logical names; a `timestamp_ntz` column is a `POSIXct`
in UTC.

## See also

[`lake_files()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
to see which files a filter keeps,
[`lake_count()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
for the number of rows from the log alone.

## Examples

``` r
# A partitioned table of two files: the data written with qio, the log by
# hand.
path <- tempfile("table")
dir.create(file.path(path, "_delta_log"), recursive = TRUE)
add <- function(year, ids) {
  file <- sprintf("year=%d/part-0.parquet", year)
  dir.create(file.path(path, dirname(file)))
  qio::write_parquet(data.frame(id = ids), file.path(path, file))
  sprintf(
    paste0(
      '{"add":{"path":"%s","partitionValues":{"year":"%d"},"size":%.0f,',
      '"modificationTime":0,"dataChange":true,"stats":"{\\"numRecords\\":%d,',
      '\\"minValues\\":{\\"id\\":%g},\\"maxValues\\":{\\"id\\":%g},',
      '\\"nullCount\\":{\\"id\\":0}}"}}'
    ),
    file, year, file.size(file.path(path, file)), length(ids), min(ids), max(ids)
  )
}
writeLines(c(
  '{"protocol":{"minReaderVersion":1,"minWriterVersion":2}}',
  paste0(
    '{"metaData":{"id":"example","format":{"provider":"parquet","options":{}},',
    '"schemaString":"{\\"type\\":\\"struct\\",\\"fields\\":[',
    '{\\"name\\":\\"id\\",\\"type\\":\\"double\\",\\"nullable\\":true,\\"metadata\\":{}},',
    '{\\"name\\":\\"year\\",\\"type\\":\\"integer\\",\\"nullable\\":true,\\"metadata\\":{}}]}",',
    '"partitionColumns":["year"],"configuration":{}}}'
  ),
  add(2025, c(1, 2, 3)),
  add(2026, c(4, 5))
), file.path(path, "_delta_log", "00000000000000000000.json"))

tbl <- lake_open(path)
lake_read(tbl)
#>   id year
#> 1  1 2025
#> 2  2 2025
#> 3  3 2025
#> 4  4 2026
#> 5  5 2026
lake_read(tbl, filter = id >= 3 & year == 2026)
#>   id year
#> 1  4 2026
#> 2  5 2026
# The statistics alone rule out the 2025 file for this filter:
lake_files(tbl, filter = id > 3)$path
#> [1] "year=2026/part-0.parquet"
lake_walk(tbl, function(piece) print(nrow(piece)))
#> [1] 3
#> [1] 2

unlink(path, recursive = TRUE)
```

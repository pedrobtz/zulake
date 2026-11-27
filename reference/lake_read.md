# Read a table's rows

`lake_read()` returns the rows of a snapshot as a data frame. It prunes
the live files with `filter` first, so that only the files whose rows
could match are read, then reads each one with qio, adds the partition
columns from the log, keeps the rows `filter` is `TRUE` for, and binds
the pieces. `lake_walk()` does the same one file at a time and calls
`FUN` on each piece instead of binding them, for tables larger than
memory (but on Azure not larger than disk; see below).

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
  (the default), exact up to 2^53 - 1 (qio returns `NA` with a warning
  past it, and a `long` partition value past 2^53 - 1 is an error of
  class `zulake_error_int64`), or `"integer64"` from the bit64 package.

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
say, and a missing statistic only means a file is read. On a column
returned as a list (a `binary` column),
[`is.na()`](https://rdrr.io/r/base/NA.html) is `TRUE` where the value is
null (`NULL`), as Delta means it, where base R's
[`is.na()`](https://rdrr.io/r/base/NA.html) on a list is `FALSE`.

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
Before R 4.3.0,
[`as.character()`](https://rdrr.io/r/base/character.html),
[`substr()`](https://rdrr.io/r/base/substr.html),
[`toupper()`](https://rdrr.io/r/base/chartr.html),
[`tolower()`](https://rdrr.io/r/base/chartr.html) and
[`grepl()`](https://rdrr.io/r/base/grep.html) of a `timestamp` or
`timestamp_ntz` column are errors of class `zulake_error_filter`, since
there a time's text depends on the other times formatted with it. Any
other call with a column inside it, such as `max(x)`, `mean(x)`,
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
a double that is not the number its 15-digit form reads back as (`1/3`,
`0.1 + 0.2`) is an error asking for the value as text. R has already
rounded a literal such as `9007199254740993` to a double
(9007199254740992) before zulake sees it, so give such a value as text
too. A `float` or `double` column takes only numbers: text there, such
as `amount > "100"`, is an error, since R would compare it with the
column as strings. A date or timestamp column takes a `Date` or
`POSIXct`, or text such as `"2024-01-31"` or `"2024-01-31 12:00:00"`
(UTC unless it gives an offset).

Columns are typed as qio returns them (see
[`qio::read_parquet()`](https://pedrobtz.github.io/qio/reference/read_parquet.html)),
and partition columns as
[`lake_files()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
types them, except that a `decimal` of precision 15 or less, data or
partition, is a double, which holds it exactly. An `integer` data value
of -2^31 reads as `NA`, R's integer `NA`, with a warning from qio:
[`is.na()`](https://rdrr.io/r/base/NA.html) is `TRUE` for it and a
comparison such as `x < 1` is not, and a file whose minimum may be -2^31
is never pruned on its null count. Columns zulake does not return are
not lost silently: nested columns (`struct`, `array`, `map`), and
decimals of precision above 15 until qio reads them exactly. With
`columns = NULL` they are left out, each named in a warning of class
`zulake_warning_column_skipped` (fields `column` and `reason`); named in
`columns` or used in `filter`, such a column is an error of class
`zulake_error_column_unreadable` with the same fields.

Data files are read in place on local disk. On Azure, every file left
after pruning is downloaded to the session's temporary directory
([`tempdir()`](https://rdrr.io/r/base/tempfile.html)) before the first
piece is read, by `lake_walk()` too, and kept there for the rest of the
session, so that a later read of the same file downloads nothing. The
disk used is the size of the files left after pruning: `lake_walk()`
reads tables larger than memory, not larger than the temporary
directory's disk.

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
# The example table the package ships: orders partitioned by region, five versions.
path <- system.file("extdata", "orders", package = "zulake")
tbl <- lake_open(path)
head(lake_read(tbl))
#>   order_id customer amount order_date region
#> 1        3     Chen 980.25 2025-01-06   APAC
#> 2        6      Fay  75.75 2025-01-06   APAC
#> 3        9      Ivo 230.40 2025-01-06   APAC
#> 4       12      Kai  19.99 2025-01-07   APAC
#> 5       15      Mia  45.00 2025-01-07   APAC
#> 6       16     Chen  70.00 2025-01-08   APAC
lake_read(tbl, columns = c("order_id", "amount"), filter = region == "EU" & amount > 100)
#>   order_id amount
#> 1        1    120
#> 2        7   1500
#> 3       13    310
#> 4       17   2500
#> 5       20    330
# Row-wise functions filter rows; dates compare as dates.
lake_read(tbl, filter = order_date >= as.Date("2025-01-08") & nchar(customer) == 3)
#>   order_id customer amount order_date region
#> 1       19      Pia   99.9 2025-01-08   APAC
#> 2       24      Tia 1999.0 2025-01-10   APAC
#> 3       17      Noa 2500.0 2025-01-08     EU
#> 4       23      Ana   55.0 2025-01-10     EU
#> 5       18      Oli   15.0 2025-01-08     US
#> 6       21      Raj  820.0 2025-01-08     US
#> 7       22      Sam  410.0 2025-01-10     US

# One file at a time, for a table larger than memory:
total <- 0
lake_walk(tbl, function(piece) total <<- total + sum(piece$amount))
total
#> [1] 11615.79
```

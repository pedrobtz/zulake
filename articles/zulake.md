# Get started with zulake

``` r

library(zulake)
```

A Delta Lake table is a folder of Parquet files plus a log that says
which files make up each version. Reading the files without the log
returns deleted and superseded rows. zulake reads the log itself: this
page opens a table, looks inside it, and then reads it.

Every section uses one table on Azure, and a function you supply that
returns a bearer token:

``` r

uri <- "abfss://lake@account.dfs.core.windows.net/sales/orders"
token <- function() my_token()
```

## Open a table

[`lake_open()`](https://pedrobtz.github.io/zulake/reference/lake_open.md)
builds a snapshot of one version, the latest unless you ask for another.
A snapshot never changes;
[`lake_load()`](https://pedrobtz.github.io/zulake/reference/lake_open.md)
gives you a new one.

``` r

tbl <- lake_open(uri, credentials = token)
lake_version(tbl)
lake_summary(tbl)
old <- lake_load(tbl, version = 3)
```

## The log as data frames

Inspection is what zulake is for. Every action in the log comes back as
a base data frame, unchanged, with nested values in list columns.

``` r

lake_history(tbl, limit = 10)
lake_schema(tbl)
lake_files(tbl)
lake_count(tbl)
lake_actions(tbl, version = lake_version(tbl))
lake_changes(tbl, from = 3)
```

Counts, sizes and statistics are 64-bit in the log. They come back as
doubles, exact up to 2^53 - 1, and an error beyond; ask for
`int64 = "integer64"` to get `bit64` integers instead. A table whose
files carry no statistics has an unknown row count:
[`lake_count()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
says so with `NA` and a warning rather than counting only the files it
can.

## Filters prune files, then rows

A filter is an R expression over column names. Partition values and
statistics drop files that cannot match before anything is downloaded;
the rows that remain are then filtered exactly, so the result never
depends on the statistics. Local values are looked up where you call.

``` r

lake_files(tbl, filter = year == 2026 & region %in% c("EU", "UK"))
yr <- 2026
lake_read(tbl, columns = c("id", "amount"), filter = year == yr)
```

## Unsupported features are refused

A table that needs a reader feature zulake does not support is refused
with an error that names the feature, before any data is read, because
ignoring it would return wrong rows.
[`lake_protocol()`](https://pedrobtz.github.io/zulake/reference/lake_versions.md)
shows which features a table uses, each marked supported; the error of a
refused table carries the same data frame.

``` r

lake_protocol(tbl)
err <- tryCatch(
  lake_open("abfss://lake@account.dfs.core.windows.net/sales/widened", credentials = token),
  zulake_error_unsupported_feature = identity
)
err$feature
err$protocol
```

## Where next

Every function is listed in the
[reference](https://pedrobtz.github.io/zulake/reference/index.html).

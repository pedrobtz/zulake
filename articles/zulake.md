# Get started with zulake

``` r

library(zulake)
```

A Delta Lake table is a folder of Parquet files plus a log that says
which files make up each version. Reading the files without the log
returns deleted and superseded rows. zulake reads the log itself: this
page opens a table, looks inside it, and then reads it.

Every section uses one table on Azure, and a function you supply that
returns a Microsoft Entra ID token for Azure Storage. zulake calls it
before its first request and again if Azure says the token has expired;
it never stores, prints or saves the token. Here the token comes from
the Azure CLI:

``` r

uri <- "abfss://lake@account.dfs.core.windows.net/sales/orders"
token <- function() {
  system2("az", c(
    "account", "get-access-token", "--resource", "https://storage.azure.com",
    "--query", "accessToken", "--output", "tsv"
  ), stdout = TRUE)
}
```

The same table is also
`https://account.dfs.core.windows.net/lake/sales/orders` or
`https://account.blob.core.windows.net/lake/sales/orders`; a local path
works too, with no `credentials`.

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
can, and `lake_count(tbl, footers = TRUE)` reads those files’ counts
from their Parquet footers.

## Filters prune files, then rows

A filter is an R expression over column names. Partition values and
statistics drop files that cannot match before anything is downloaded;
the rows that remain are then filtered exactly, so the result never
depends on the statistics. Local values are looked up where you call.
Numbers in integer and decimal columns compare exactly, so a value a
double cannot write exactly is given as text; strings compare in UTF-8
byte order.

``` r

lake_files(tbl, filter = year == 2026 & region %in% c("EU", "UK"))
yr <- 2026
lake_read(tbl, columns = c("id", "amount"), filter = year == yr & amount > "1000.10")
```

[`lake_walk()`](https://pedrobtz.github.io/zulake/reference/lake_read.md)
reads one file at a time and hands each piece to a function, for a table
larger than memory. Columns qio cannot return yet (nested columns,
decimals of more than 15 digits) are left out with a warning naming
each.

``` r

total <- 0
lake_walk(tbl, function(piece) total <<- total + sum(piece$amount), filter = year == yr)
```

A filter is decided row by row. Besides comparisons it may use row-wise
functions such as [`nchar()`](https://rdrr.io/r/base/nchar.html),
[`round()`](https://rdrr.io/r/base/Round.html) or arithmetic, which
filter rows but never rule out files; a call that looks at other rows,
such as `amount > mean(amount)`, is an error, because its answer would
depend on how the table is split into files.

``` r

lake_read(tbl, filter = year == yr & nchar(region) == 2 & amount * 1.2 > 1000)
```

## Deletion vectors

Tables written by Databricks delete rows by marking them in a deletion
vector rather than rewriting the file. zulake never returns a marked
row.
[`lake_deletion_vectors()`](https://pedrobtz.github.io/zulake/reference/lake_deletion_vectors.md)
shows each file’s vector and the rows it deletes; reading those rows
needs the zuroar package, while the descriptors and
[`lake_count()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
come from the log alone.

``` r

lake_deletion_vectors(tbl, rows = FALSE)
dv <- lake_deletion_vectors(tbl)
dv$rows[[1]]
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

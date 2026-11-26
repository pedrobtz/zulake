# Get started with zulake

``` r

library(zulake)
```

A Delta Lake table is a folder of Parquet files plus a log that says
which files make up each version. Reading the files without the log
returns deleted and superseded rows. zulake reads the log itself: on
this page we open a table, look inside its log, and then read it with a
filter. Reading a table on Azure is the last section; everything before
it runs on a table that ships with the package.

## Open a table

The example table holds a few orders, partitioned by `region`, written
in five commits on five days.
[`lake_open()`](https://pedrobtz.github.io/zulake/reference/lake_open.md)
builds a **snapshot** of one version, the latest unless you ask for
another.

``` r

path <- system.file("extdata", "orders", package = "zulake")
tbl <- lake_open(path)
tbl
#> <zulake_table> delta table, version 4
#> uri:       /home/runner/work/_temp/Library/zulake/extdata/orders
#> committed: 2025-01-10 09:00:00 UTC
#> files:     12 (16890 bytes)
#> records:   23
```

A snapshot never changes.
[`lake_versions()`](https://pedrobtz.github.io/zulake/reference/lake_versions.md)
lists the versions the log still holds, with the time each was
committed, and
[`lake_load()`](https://pedrobtz.github.io/zulake/reference/lake_open.md)
gives you a snapshot of another one, by number or by time.

``` r

lake_versions(tbl)
#>   version           timestamp
#> 1       0 2025-01-06 09:00:00
#> 2       1 2025-01-07 09:00:00
#> 3       2 2025-01-08 09:00:00
#> 4       3 2025-01-09 09:00:00
#> 5       4 2025-01-10 09:00:00
old <- lake_load(tbl, timestamp = as.POSIXct("2025-01-08 12:00", tz = "UTC"))
lake_version(old)
#> [1] 2
```

## The log as data frames

Inspection is what zulake is for. Each function answers one question
from the log alone, as a base data frame, with nested values in list
columns. The history says what each commit did:

``` r

lake_history(tbl)[c("version", "timestamp", "operation")]
#>   version           timestamp operation
#> 1       4 2025-01-10 09:00:00     WRITE
#> 2       3 2025-01-09 09:00:00    DELETE
#> 3       2 2025-01-08 09:00:00     WRITE
#> 4       1 2025-01-07 09:00:00     WRITE
#> 5       0 2025-01-06 09:00:00     WRITE
lake_schema(tbl)[c("name", "type", "partition")]
#>         name   type partition
#> 1   order_id   long     FALSE
#> 2   customer string     FALSE
#> 3     amount double     FALSE
#> 4 order_date   date     FALSE
#> 5     region string      TRUE
```

[`lake_files()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
lists the files of the snapshot with their partition values and
statistics;
[`lake_count()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
adds up the row counts the statistics record, without reading a file.

``` r

files <- lake_files(tbl)
files[c("path", "size_bytes", "num_records")]
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
lake_count(tbl)
#> [1] 23
```

Version 3 deleted one order.
[`lake_actions()`](https://pedrobtz.github.io/zulake/reference/lake_log.md)
shows that commit as the log holds it, and
[`lake_changes()`](https://pedrobtz.github.io/zulake/reference/lake_log.md)
the files it took away and added: the file that held the order is
replaced by one with its other rows.

``` r

lake_actions(tbl, version = 3)[c("line", "type")]
#>   line       type
#> 1    1 commitInfo
#> 2    2        add
#> 3    3     remove
lake_changes(tbl, from = 2, to = 3)[c("change", "path")]
#>    change                        path
#> 1   added region=US/part-0010.parquet
#> 2 removed region=US/part-0003.parquet
```

The last commit also recorded the version of the application that wrote
it, which a loader uses to avoid writing the same batch twice:

``` r

lake_transactions(tbl)
#>          app_id version        last_updated
#> 1 orders-loader       4 2025-01-10 09:00:00
```

Counts, sizes and statistics are 64-bit in the log. They come back as
doubles, exact up to 2^53 - 1, and an error beyond; ask for
`int64 = "integer64"` to get `bit64` integers instead.

## Filters prune files, then rows

A **filter** is an R expression over column names. Partition values and
statistics rule out files that cannot match before anything is read: of
the twelve files, only two can hold an order from the EU over 1000.

``` r

lake_files(tbl, filter = region == "EU" & amount > 1000)$path
#> [1] "region=EU/part-0002.parquet" "region=EU/part-0008.parquet"
```

[`lake_read()`](https://pedrobtz.github.io/zulake/reference/lake_read.md)
reads the files that remain and then filters their rows, so the result
never depends on the statistics. Local values are looked up where you
call, and dates compare as dates.

``` r

since <- as.Date("2025-01-08")
lake_read(tbl, columns = c("order_id", "customer", "amount"),
          filter = order_date >= since & amount > 300)
#>   order_id customer amount
#> 1       24      Tia   1999
#> 2       17      Noa   2500
#> 3       20     Dara    330
#> 4       21      Raj    820
#> 5       22      Sam    410
```

Besides comparisons, a filter may use row-wise functions such as
[`nchar()`](https://rdrr.io/r/base/nchar.html),
[`round()`](https://rdrr.io/r/base/Round.html) or arithmetic, which
filter rows but never rule out files. A call that looks at other rows is
an error, because its answer would depend on how the table is split into
files:

``` r

lake_read(tbl, filter = amount > mean(amount))
#> Error:
#> ! `filter` cannot use amount > mean(amount): mean() is applied to a column but is not row-wise. A filter is comparisons (==, !=, <, <=, >, >=), %in% and is.na() between a column and values, and the row-wise functions listed in ?lake_read, joined by !, & and |.
```

[`lake_walk()`](https://pedrobtz.github.io/zulake/reference/lake_read.md)
reads one file at a time and hands each piece to a function, for a table
larger than memory:

``` r

total <- 0
lake_walk(tbl, function(piece) total <<- total + sum(piece$amount),
          filter = region == "US")
total
#> [1] 3180.5
```

## Deletion vectors and other features

Tables written by Databricks often delete rows by marking them in a
**deletion vector** rather than rewriting the file as the delete above
did. zulake never returns a marked row.
[`lake_deletion_vectors()`](https://pedrobtz.github.io/zulake/reference/lake_deletion_vectors.md)
shows each file’s vector and the rows it deletes; this table has none.
Reading those rows needs the zuroar package, while the descriptors and
[`lake_count()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
come from the log alone.

``` r

lake_deletion_vectors(tbl, rows = FALSE)
#> [1] uri               storage_type      path_or_inline_dv offset           
#> [5] size_in_bytes     cardinality      
#> <0 rows> (or 0-length row.names)
```

A table that needs a reader feature zulake does not support is refused,
with an error that names the feature, before any data is read, because
ignoring the feature would return wrong rows.
[`lake_protocol()`](https://pedrobtz.github.io/zulake/reference/lake_versions.md)
shows the features a table uses, each marked supported; this one uses
in-commit timestamps, which only writers must know about.

``` r

lake_protocol(tbl)
#>                name reader writer version supported
#> 1     readerVersion   TRUE  FALSE       1      TRUE
#> 2     writerVersion  FALSE   TRUE       7      TRUE
#> 3 inCommitTimestamp  FALSE   TRUE      NA      TRUE
```

## Tables on Azure

The same functions read a table on Azure Data Lake Storage Gen2 or Blob
Storage. You supply a function that returns a Microsoft Entra ID token
for Azure Storage; zulake calls it before its first request and again if
Azure says the token has expired, and never stores, prints or saves the
token. Here the token comes from the Azure CLI (not run on this page):

``` r

token <- function() {
  system2("az", c(
    "account", "get-access-token", "--resource", "https://storage.azure.com",
    "--query", "accessToken", "--output", "tsv"
  ), stdout = TRUE)
}
tbl <- lake_open("abfss://lake@account.dfs.core.windows.net/sales/orders",
                 credentials = token)
lake_files(tbl, filter = region == "EU")
```

The same table is also
`https://account.dfs.core.windows.net/lake/sales/orders` or
`https://account.blob.core.windows.net/lake/sales/orders`.

## Where next

- [`?lake_read`](https://pedrobtz.github.io/zulake/reference/lake_read.md)
  lists every function a filter may use, and how values compare.
- [`?lake_files`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
  describes each column of the file list and the statistics.
- [`?lake_open`](https://pedrobtz.github.io/zulake/reference/lake_open.md)
  covers versions, timestamps, Azure URIs and credentials.
- The
  [reference](https://pedrobtz.github.io/zulake/reference/index.html)
  lists every function.

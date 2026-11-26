
<!-- README.md is generated from README.Rmd. Please edit that file -->

# zulake

<!-- badges: start -->

[![R-CMD-check](https://github.com/pedrobtz/zulake/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/pedrobtz/zulake/actions/workflows/R-CMD-check.yaml)
[![coverage](https://raw.githubusercontent.com/pedrobtz/zulake/gh-pages/badges/coverage.svg)](https://github.com/pedrobtz/zulake/actions/workflows/coverage.yaml)
<!-- badges: end -->

zulake is an R package that opens a Delta Lake table where it is stored
and returns what the table’s log records as base data frames.

- It replays the log in R, as the [Delta Lake
  protocol](https://github.com/delta-io/delta/blob/master/PROTOCOL.md)
  prescribes: versions, commits, live files with their partition values
  and statistics, deletion vectors, schema and the changes between
  versions.
- It reads the data too, ruling out files by partition values and
  statistics before reading any of them.
- Tables can be on local disk, Azure Data Lake Storage Gen2 or Azure
  Blob Storage, with a bearer token from a function you supply.
- A table that needs a feature zulake does not support is refused by
  name, never read wrong.

## Installation

zulake is not on CRAN yet. Install the development version from GitHub:

``` r
# install.packages("pak")
pak::pak("pedrobtz/zulake")
```

## Usage

The package ships a small table of orders, partitioned by region. Open
it, and list the files that can hold an order from the EU over 1000:

``` r
library(zulake)

tbl <- lake_open(system.file("extdata", "orders", package = "zulake"))
lake_files(tbl, filter = region == "EU" & amount > 1000)[c("path", "num_records")]
#>                          path num_records
#> 1 region=EU/part-0002.parquet           3
#> 2 region=EU/part-0008.parquet           2
```

zulake also lists the table’s history and changes, and reads its rows;
[Get started](https://pedrobtz.github.io/zulake/articles/zulake.html)
shows each of them.

## Learn more

- [Get started](https://pedrobtz.github.io/zulake/articles/zulake.html):
  open a table, inspect its log, read it with a filter, and read from
  Azure.
- [Reference](https://pedrobtz.github.io/zulake/reference/index.html):
  every function, the data frames they return and the errors they raise.
- [Changelog](https://pedrobtz.github.io/zulake/news/index.html): what
  each version changed.

zulake reads tables and does not write them; to write one, use the
Python [`deltalake`](https://delta-io.github.io/delta-rs/) package or
Spark.

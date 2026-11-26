# Is there a table here?

`lake_is_table()` says whether `uri` holds a Delta Lake table: a
`_delta_log/` directory with at least one commit or checkpoint in it. It
reads no log file, so a table it finds can still fail to open.

## Usage

``` r
lake_is_table(uri, credentials = NULL)
```

## Arguments

- uri:

  Location of the table, the directory that holds `_delta_log/`: a local
  path, or an Azure URI in one of the forms of the Azure section.

- credentials:

  A function of no arguments returning a bearer token for Azure Storage,
  as a string (see the Azure section), or `NULL` for anonymous requests.
  Not used for local paths.

## Value

`TRUE` or `FALSE`.

## See also

[`lake_open()`](https://pedrobtz.github.io/zulake/reference/lake_open.md),
whose example also calls `lake_is_table()`.

## Examples

``` r
lake_is_table(system.file("extdata", "orders", package = "zulake"))
#> [1] TRUE
lake_is_table(tempdir())
#> [1] FALSE
```

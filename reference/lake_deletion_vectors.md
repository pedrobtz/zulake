# Deletion vectors

`lake_deletion_vectors()` lists the deletion vectors of a snapshot's
live files: one row per file that has one, with the descriptor the log
holds and, with `rows = TRUE`, the rows it deletes. A deletion vector
marks rows of a data file as deleted without rewriting the file;
[`lake_read()`](https://pedrobtz.github.io/zulake/reference/lake_read.md)
and
[`lake_walk()`](https://pedrobtz.github.io/zulake/reference/lake_read.md)
never return those rows, and
[`lake_count()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
subtracts their number.

## Usage

``` r
lake_deletion_vectors(tbl, files = NULL, rows = TRUE)
```

## Arguments

- tbl:

  A snapshot, from
  [`lake_open()`](https://pedrobtz.github.io/zulake/reference/lake_open.md).

- files:

  `NULL`, the default, for every live file, or a character vector of
  files, each a `path` or `uri` as
  [`lake_files()`](https://pedrobtz.github.io/zulake/reference/lake_files.md)
  gives them.

- rows:

  Whether to read each vector and return the rows it deletes. With
  `FALSE`, only the descriptors from the log are returned: nothing is
  read, and zuroar is not needed.

## Value

A data frame with one row per live file that has a deletion vector, in
the order of
[`lake_files()`](https://pedrobtz.github.io/zulake/reference/lake_files.md):
`uri` (the data file), `storage_type`, `path_or_inline_dv`, `offset`
(`NA` for an inline vector), `size_in_bytes` and `cardinality` (the
number of rows deleted), all from the log, and with `rows = TRUE`,
`rows`, a list column of the deleted rows' positions in the data file:
sorted doubles, counted from 0 as the protocol counts them. A position
of 2^53 or more, which a double cannot hold exactly, is an error of
class `zulake_error_int64`.

## Details

A descriptor's `storage_type` says where the vector is: `"i"` inline in
the log (`path_or_inline_dv` is the vector itself, Z85-encoded), `"u"`
in a file of the table whose name is derived from a UUID
(`path_or_inline_dv` is an optional prefix and the Z85-encoded UUID), or
`"p"` in a file at an absolute path. A vector in a file is read by range
at `offset`, and its CRC-32 checksum is verified. The rows are those of
the Roaring bitmap the vector holds, decoded by the zuroar package,
which zulake suggests rather than imports: without it, `rows = TRUE`,
and any read of a table with deletion vectors, is an error of class
`zulake_error_missing_package` naming `zuroar`.

A vector whose checksum, magic number, size or row count does not agree
with its descriptor is an error of class `zulake_error_corrupt_log`, and
no rows are returned.

## See also

[`lake_files()`](https://pedrobtz.github.io/zulake/reference/lake_files.md),
whose `deletion_vector` column holds the same descriptors.

## Examples

``` r
# The example table the package ships has no deletion vector:
orders <- lake_open(system.file("extdata", "orders", package = "zulake"))
lake_deletion_vectors(orders, rows = FALSE)
#> [1] uri               storage_type      path_or_inline_dv offset           
#> [5] size_in_bytes     cardinality      
#> <0 rows> (or 0-length row.names)

# A table of one file of ten rows, whose rows 0 and 9 are deleted by a
# deletion vector written inline in the log.
path <- tempfile("table")
dir.create(file.path(path, "_delta_log"), recursive = TRUE)
qio::write_parquet(data.frame(value = 0:9), file.path(path, "part-0.parquet"))
writeLines(c(
  paste0(
    '{"protocol":{"minReaderVersion":3,"minWriterVersion":7,',
    '"readerFeatures":["deletionVectors"],"writerFeatures":["deletionVectors"]}}'
  ),
  paste0(
    '{"metaData":{"id":"example","format":{"provider":"parquet","options":{}},',
    '"schemaString":"{\\"type\\":\\"struct\\",\\"fields\\":[',
    '{\\"name\\":\\"value\\",\\"type\\":\\"integer\\",\\"nullable\\":true,\\"metadata\\":{}}]}",',
    '"partitionColumns":[],"configuration":{}}}'
  ),
  sprintf(
    paste0(
      '{"add":{"path":"part-0.parquet","partitionValues":{},"size":%.0f,',
      '"modificationTime":0,"dataChange":true,"stats":"{\\"numRecords\\":10}",',
      '"deletionVector":{"storageType":"i",',
      '"pathOrInlineDv":"^Bg9^0rr910000000000iXQKl0rr91000315c8Xg000r9",',
      '"sizeInBytes":36,"cardinality":2}}}'
    ),
    file.size(file.path(path, "part-0.parquet"))
  )
), file.path(path, "_delta_log", "00000000000000000000.json"))

tbl <- lake_open(path)
lake_deletion_vectors(tbl, rows = FALSE)
#>                                                uri storage_type
#> 1 /tmp/RtmpoB08A7/table1b78694f76b9/part-0.parquet            i
#>                               path_or_inline_dv offset size_in_bytes
#> 1 ^Bg9^0rr910000000000iXQKl0rr91000315c8Xg000r9     NA            36
#>   cardinality
#> 1           2
lake_count(tbl)
#> [1] 8
if (requireNamespace("zuroar", quietly = TRUE)) {
  print(lake_deletion_vectors(tbl)$rows)
  print(lake_read(tbl))
}
#> [[1]]
#> [1] 0 9
#> 
#>   value
#> 1     1
#> 2     2
#> 3     3
#> 4     4
#> 5     5
#> 6     6
#> 7     7
#> 8     8

unlink(path, recursive = TRUE)
```

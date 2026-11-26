# Without zuroar, a table with deletion vectors cannot be read: the read is
# a classed error naming zuroar, and the log alone still answers (design
# D9, D12). This runs under R CMD check on every leg but checks only where
# zuroar is not installed: CRAN's NOSUGGESTS flavor, the `nosuggests` job of
# the full r-actions profile, which also has no testthat. Elsewhere
# tests/testthat/test-dv.R checks the same with zuroar's absence mocked.
if (!requireNamespace("zuroar", quietly = TRUE)) {
  library(zulake)
  dir <- tempfile("zulake-fixtures-")
  dir.create(dir)
  utils::untar(file.path("testthat", "fixtures", "delta-fixtures.tar"), exdir = dir, tar = "internal")
  for (table in c("table-with-dv-small", "table-with-dv-small-inline", "deletion_vectors")) {
    tbl <- lake_open(file.path(dir, "tables", table))
    for (f in list(function() lake_read(tbl), function() lake_walk(tbl, print),
                   function() lake_deletion_vectors(tbl))) {
      err <- tryCatch(f(), error = identity)
      stopifnot(
        inherits(err, "zulake_error_missing_package"),
        inherits(err, "zulake_error"),
        identical(err$package, "zuroar"),
        grepl("zuroar", conditionMessage(err), fixed = TRUE)
      )
    }
    stopifnot(nrow(lake_deletion_vectors(tbl, rows = FALSE)) == 1L)
  }
  stopifnot(identical(lake_count(lake_open(file.path(dir, "tables", "table-with-dv-small"))), 8))
  # A version without a deletion vector reads.
  stopifnot(nrow(lake_read(lake_open(file.path(dir, "tables", "table-with-dv-small"), version = 0))) == 10L)
  unlink(dir, recursive = TRUE)
  cat("zuroar is absent: reads of deletion-vector tables are refused by name\n")
} else {
  cat("zuroar is installed: tests/testthat/test-dv.R covers its absence\n")
}

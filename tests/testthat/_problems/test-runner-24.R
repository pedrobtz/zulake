# Extracted from test-runner.R:24

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "zulake", path = "..")
attach(test_env, warn.conflicts = FALSE)

# prequel ----------------------------------------------------------------------
run_order <- function(seed, shuffle = TRUE) {
  dir <- withr::local_tempdir()
  log <- file.path(dir, "order.log")
  path <- file.path(dir, "test-order.R")
  writeLines(
    sprintf(
      'test_that("t%1$02d", { cat("%1$d\\n", file = "%2$s", append = TRUE); succeed() })',
      1:20,
      log
    ),
    path
  )
  withr::with_seed(seed, {
    testthat::test_file(path, reporter = "silent", shuffle = shuffle)
  })
  as.integer(readLines(log))
}

# test -------------------------------------------------------------------------
first <- run_order(20261126L)

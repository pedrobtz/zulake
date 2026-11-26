# Runs a 20-test file under `seed` and returns the order its tests ran in.
# A helper, not part of test-runner.R: the shuffle reorders every top-level
# expression of a test file, a function definition included.
run_order <- function(seed, shuffle = TRUE) {
  dir <- withr::local_tempdir()
  log <- file.path(dir, "order.log")
  path <- file.path(dir, "test-order.R")
  writeLines(
    sprintf(
      'test_that("t%1$02d", { cat("%1$d\\n", file = %2$s, append = TRUE); succeed() })',
      1:20,
      # Quoted and escaped, since a Windows temporary path has backslashes.
      encodeString(log, quote = "\"")
    ),
    path
  )
  withr::with_seed(seed, {
    testthat::test_file(path, reporter = "silent", shuffle = shuffle)
  })
  as.integer(readLines(log))
}

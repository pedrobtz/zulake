# The suite as R CMD check and covr (r-actions coverage.yml) run it, and as
# tools/ci-run-tests.R runs it from the source tree.
#
# Shuffled: the top-level expressions of each test file run in a random
# order, so a test that leans on another's leftovers fails here rather than
# staying invisible. The seed is printed first; ZULAKE_TEST_SEED replays an
# order.
#
# The seed line reaches the CI log through check-r-package's "Show testthat
# output" step, which prints this file's .Rout on every run.

if (requireNamespace("testthat", quietly = TRUE)) {
  library(testthat)
  library(zulake)

  seed <- suppressWarnings(as.integer(Sys.getenv("ZULAKE_TEST_SEED")))
  if (is.na(seed)) {
    seed <- sample.int(.Machine$integer.max, 1L)
  }
  cat("zulake test order seed:", seed, "(ZULAKE_TEST_SEED to replay)\n")
  set.seed(seed)

  test_check("zulake", shuffle = TRUE)
}

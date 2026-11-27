# How many seeded random cases a property or fuzz test draws: `full` off
# CRAN (NOT_CRAN=true, which CI and tools/ci-run-tests.R set), `cran`
# otherwise, so that CRAN's check stays inside its time budget while every
# test, with its oracle, still runs there. tests/testthat.R prints the mode
# next to the seed. A reduced count draws fewer random values, so a
# ZULAKE_TEST_SEED replays a failure only in the mode that printed it.
test_iterations <- function(full, cran) {
  if (identical(Sys.getenv("NOT_CRAN"), "true")) full else cran
}

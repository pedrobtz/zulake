# Runs the suite shuffled from the source tree, exactly as R CMD check and
# covr run it: tests/testthat.R, against the installed package.
#
#   R CMD INSTALL .
#   Rscript tools/ci-run-tests.R                        # prints its seed
#   ZULAKE_TEST_SEED=<seed> Rscript tools/ci-run-tests.R # replays that order
#
# The shuffle and the seed live in tests/testthat.R, not here, because
# r-actions' coverage.yml has no input for a runner: covr runs the installed
# tests/ directory, and tools/ is not installed. Keeping one copy means the
# order replayed here is the order CI ran.
if (!file.exists("tests/testthat.R")) {
  stop("run from the package root: Rscript tools/ci-run-tests.R", call. = FALSE)
}
# Full counts for the seeded random tests (helper-iterations.R), as in CI;
# NOT_CRAN=false runs the reduced counts CRAN runs.
if (!nzchar(Sys.getenv("NOT_CRAN"))) Sys.setenv(NOT_CRAN = "true")
setwd("tests")
source("testthat.R", echo = FALSE)

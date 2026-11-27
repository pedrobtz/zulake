# Helpers for test-helpers.R, the failure tests of the assertion helpers
# (#82). Here, not in a test file, because the suite shuffles every
# top-level expression of a test file.

# The expectations `code` signals, counted and muffled: list(success,
# failure). testthat's expect_failure() wants exactly one failure and no
# success, and a helper such as expect_no_token() makes several
# expectations, so its tests count them instead.
expectation_counts <- function(code) {
  n <- c(success = 0L, failure = 0L)
  withCallingHandlers(
    code,
    expectation_success = function(cnd) {
      n[["success"]] <<- n[["success"]] + 1L
      invokeRestart("muffle_expectation")
    },
    expectation_failure = function(cnd) {
      n[["failure"]] <<- n[["failure"]] + 1L
      invokeRestart("muffle_expectation")
    }
  )
  as.list(n)
}

# An object whose printed form shows a token its serialization does not
# hold (the bytes are reversed), for expect_no_token()'s printed-form check.
print.zulake_test_shows_token <- function(x, ...) {
  cat(rawToChar(rev(x$reversed)), "\n")
  invisible(x)
}

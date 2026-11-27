# A hostile session for the locale tests (#81). Here, not in a test file,
# because the suite shuffles every top-level expression of a test file.
#
# testthat 3e already runs each test in the C collation, so asking for "C"
# changes nothing, and setting LC_ALL as an environment variable does not
# change the running session's locale. local_hostile_locale() changes the
# session itself: a collation in which "a" sorts before "B" (not byte
# order), the C character type (not UTF-8), and number formatting that
# writes 1.5 as "1,5e+00" with 3 digits.

# The character type the session started in, in which the oracles evaluate
# R (oracle_locale()): R translates a string to the native encoding to
# compare it, and in the C type "café" becomes "caf<U+00E9>".
session_ctype <- Sys.getlocale("LC_CTYPE")

# `code` evaluated as the oracles evaluate R, whatever the test's session: in
# the C collation, so that strings compare in byte order as zulake's filters
# do, and in the character type the session started in.
with_oracle_locale <- function(code) {
  withr::with_locale(c(LC_COLLATE = "C", LC_CTYPE = session_ctype), code)
}

# Whether the session's collation sorts "a" before "B", which byte order
# does not. Through sort(), not `"a" < "B"`: R's byte-code compiler folds a
# comparison of two constants in the collation it compiles in.
byte_order_broken <- function() {
  identical(sort(c("B", "a")), c("a", "B"))
}

# The first installed collation that is not byte order, or NA.
hostile_collation <- function() {
  for (collate in c("en_US.UTF-8", "en_US.utf8", "English_United States.1252", "en-US")) {
    ok <- tryCatch(
      withr::with_collate(collate, identical(Sys.getlocale("LC_COLLATE"), collate) && byte_order_broken()),
      warning = function(w) FALSE,
      error = function(e) FALSE
    )
    if (isTRUE(ok)) {
      return(collate)
    }
  }
  NA_character_
}

# Puts the calling test in the hostile session until it ends; skips when no
# such collation is installed.
local_hostile_locale <- function(env = parent.frame()) {
  collate <- hostile_collation()
  if (is.na(collate)) {
    testthat::skip("no collation other than byte order is installed")
  }
  withr::local_collate(collate, .local_envir = env)
  withr::local_locale(c(LC_CTYPE = "C"), .local_envir = env)
  withr::local_options(OutDec = ",", scipen = -5, digits = 3, .local_envir = env)
  stopifnot(byte_order_broken(), identical(format(1.5), "1,5e+00"))
  invisible(collate)
}

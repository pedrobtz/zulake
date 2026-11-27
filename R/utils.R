# Argument checks and small predicates.

# Largest whole number a double holds exactly together with its neighbours:
# versions and timestamps are doubles, exact below 2^53 (design section 7).
max_exact <- 2^53 - 1

is_string <- function(x) {
  is.character(x) && length(x) == 1L && !is.na(x)
}

is_number <- function(x) {
  is.numeric(x) && !inherits(x, c("factor", "POSIXt", "Date")) && length(x) == 1L && !is.na(x)
}

is_whole <- function(x) {
  is_number(x) && is.finite(x) && x == trunc(x)
}

check_string <- function(x, arg) {
  if (!is_string(x) || !nzchar(x)) {
    zulake_abort("argument", sprintf("`%s` must be a single non-empty string.", arg))
  }
  invisible(x)
}

# A number argument as a double: an integer64 converted exactly, or Inf
# past 2^53 - 1, where a double is no longer exact, so that every check
# refuses it; anything else as given. seq_len() and arithmetic read an
# integer64's bits as a double, so none reaches them (#60).
arg_number <- function(x) {
  if (!inherits(x, "integer64")) {
    return(x)
  }
  if (length(x) != 1L || is.na(x)) {
    return(NA_real_)
  }
  text <- as.character(x)
  if (integer_past_exact(text)) Inf else as.numeric(text)
}

# A version argument: NULL, or one whole number from 0 to 2^53 - 1.
check_version <- function(version) {
  if (is.null(version)) {
    return(NULL)
  }
  version <- arg_number(version)
  if (!is_whole(version) || version < 0 || version > max_exact) {
    zulake_abort(
      "argument",
      "`version` must be NULL or a single whole number from 0 to 2^53 - 1."
    )
  }
  as.numeric(version)
}

# A timestamp argument: NULL, or one POSIXct that is not NA.
check_timestamp <- function(timestamp) {
  if (is.null(timestamp)) {
    return(NULL)
  }
  if (!inherits(timestamp, "POSIXct") || length(timestamp) != 1L || !is.finite(unclass(timestamp))) {
    zulake_abort("argument", "`timestamp` must be NULL or a single POSIXct date-time.")
  }
  timestamp
}

check_table <- function(tbl) {
  if (!inherits(tbl, "zulake_table")) {
    zulake_abort("argument", "`tbl` must be a table snapshot from lake_open().")
  }
  invisible(tbl)
}

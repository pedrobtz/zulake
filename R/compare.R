# Exact comparisons for filters (design section 6).
#
# Three kinds of column compare three ways, the same in pruning and in rows:
#
#   "exact"   byte, short, integer, long and decimal columns: numbers as
#             decimal text, compared digit by digit at any precision, so a
#             64-bit value or a decimal is never rounded through a double
#   "number"  float, double, boolean, date and timestamp columns: doubles
#             (days for a date, seconds for a timestamp, 0 and 1 for a
#             boolean), compared by R
#   "bytes"   string columns: UTF-8 text in byte order, whatever the
#             session's collation, as the protocol's statistics are
#
# Any other column (binary, nested) has no kind: a comparison on it is
# evaluated by R on rows and decides nothing in pruning.

# The kind of a Delta type, or NA.
type_kind <- function(type) {
  if (is.na(type)) {
    return(NA_character_)
  }
  if (type %in% c("byte", "short", "integer", "long") || grepl("^decimal", type)) {
    return("exact")
  }
  if (type %in% c("float", "double", "boolean", "date", "timestamp", "timestamp_ntz")) {
    return("number")
  }
  if (type == "string") {
    return("bytes")
  }
  NA_character_
}

# Precision and scale of "decimal(p,s)", or NULL for another type.
decimal_ps <- function(type) {
  m <- regmatches(type, regexec("^decimal\\(\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*\\)$", type))[[1L]]
  if (length(m) != 3L) {
    return(NULL)
  }
  c(precision = as.numeric(m[2L]), scale = as.numeric(m[3L]))
}

# Decimals a double holds exactly: every decimal of at most 15 significant
# digits is a distinct double (DBL_DIG), and its unscaled integer is below
# 2^53 (design section 7).
max_double_precision <- 15

# ---- exact decimal text ----------------------------------------------------

exact_pattern <- "^([+-]?)([0-9]+)(?:[.]([0-9]+))?(?:[eE]([+-]?[0-9]+))?$"

# Whether each string is a decimal number `[+-]digits[.digits][e[+-]n]`.
is_exact_text <- function(x) {
  !is.na(x) & grepl(exact_pattern, x, perl = TRUE)
}

# Decimal text as list(sign, exp, digits): the value is
# sign * 0.<digits> * 10^exp, with `digits` free of leading and trailing
# zeros, so equal values have equal parts. Zero has sign 0 and no digits;
# "Inf" and "-Inf" have exp Inf. NA or text that is not a number gives NA
# parts.
exact_parse <- function(x) {
  n <- length(x)
  sign <- rep(NA_real_, n)
  exp <- rep(NA_real_, n)
  digits <- rep(NA_character_, n)
  inf <- !is.na(x) & x %in% c("Inf", "-Inf")
  sign[inf] <- ifelse(x[inf] == "Inf", 1, -1)
  exp[inf] <- Inf
  digits[inf] <- ""
  ok <- is_exact_text(x)
  if (any(ok)) {
    y <- x[ok]
    part <- function(i) sub(exact_pattern, sprintf("\\%d", as.integer(i)), y, perl = TRUE)
    int <- part(2)
    frac <- part(3)
    e <- part(4)
    all <- paste0(int, frac)
    lead <- nchar(all) - nchar(sub("^0+", "", all))
    d <- sub("0+$", "", substring(all, lead + 1L))
    e_num <- ifelse(nzchar(e), suppressWarnings(as.numeric(e)), 0)
    zero <- !nzchar(d)
    sign[ok] <- ifelse(zero, 0, ifelse(part(1) == "-", -1, 1))
    exp[ok] <- ifelse(zero, 0, nchar(int) + e_num - lead)
    digits[ok] <- d
  }
  list(sign = sign, exp = exp, digits = digits)
}

# Digits after the decimal point in each parsed value (0 for an integer).
exact_fraction_digits <- function(p) {
  out <- pmax(0, nchar(p$digits) - p$exp)
  out[is.infinite(p$exp)] <- 0
  out
}

# -1, 0 or 1 as `a` is below, equal to or above `b` (parsed values, `b`
# recycled), NA where either is NA.
exact_cmp <- function(a, b) {
  n <- max(length(a$sign), length(b$sign))
  if (!length(a$sign) || !length(b$sign)) {
    return(integer())
  }
  rep_p <- function(p) lapply(p, rep_len, length.out = n)
  a <- rep_p(a)
  b <- rep_p(b)
  out <- rep(NA_integer_, n)
  ok <- !is.na(a$sign) & !is.na(b$sign)
  s <- sign(a$sign - b$sign)
  out[ok] <- as.integer(s[ok])
  same <- ok & s == 0 & a$sign != 0
  if (any(same)) {
    mag <- as.integer(sign(a$exp[same] - b$exp[same]))
    tie <- mag == 0L
    tie[is.na(tie)] <- TRUE
    if (any(tie)) {
      mag[tie] <- bytes_cmp(a$digits[same][tie], b$digits[same][tie])
    }
    out[same] <- mag * as.integer(a$sign[same])
  }
  out
}

# -1, 0 or 1 comparing strings in byte order (C collation), `b` recycled,
# NA where either is NA. A string that is a prefix of another sorts first.
bytes_cmp <- function(a, b) {
  n <- max(length(a), length(b))
  if (!length(a) || !length(b)) {
    return(integer())
  }
  a <- rep_len(enc2utf8(as.character(a)), n)
  b <- rep_len(enc2utf8(as.character(b)), n)
  u <- unique(c(a, b))
  u <- u[!is.na(u)]
  rank <- match(u, u[order(u, method = "radix")])
  out <- as.integer(sign(rank[match(a, u)] - rank[match(b, u)]))
  out[is.na(a) | is.na(b)] <- NA_integer_
  out
}

# Whether each of `x` starts with `prefix` (recycled), byte for byte.
bytes_starts_with <- function(x, prefix) {
  out <- startsWith(enc2utf8(x), enc2utf8(prefix))
  out[is.na(out)] <- FALSE
  out
}

# ---- filter values as comparison keys --------------------------------------

# The values of a filter literal compared with a column of `kind` (and Delta
# type `type`), as keys: parsed decimal text for "exact", doubles for
# "number", UTF-8 strings for "bytes". NA (and NaN, which equals nothing in
# a comparison) stays NA; `nan` says which elements were NaN.
literal_keys <- function(value, kind, type, expr) {
  if (is.factor(value)) {
    value <- as.character(value)
  }
  switch(kind,
    exact = literal_exact(value, expr),
    number = literal_number(value, type, expr),
    bytes = list(keys = enc2utf8(as.character(value)), nan = rep(FALSE, length(value)))
  )
}

literal_exact <- function(value, expr) {
  n <- length(value)
  text <- rep(NA_character_, n)
  nan <- rep(FALSE, n)
  if (inherits(value, "integer64")) {
    text <- as.character(value)
  } else if (is.character(value)) {
    bad <- !is.na(value) & !is_exact_text(value)
    if (any(bad)) {
      filter_error(expr, sprintf("%s is not a number", format_string(value[bad][1L])))
    }
    text <- value
  } else if (is.logical(value) || is.integer(value)) {
    have <- !is.na(value)
    text[have] <- sprintf("%d", as.integer(value[have]))
  } else if (is.double(value)) {
    x <- as.numeric(unclass(value))
    nan <- is.nan(x)
    text[x %in% Inf] <- "Inf"
    text[x %in% -Inf] <- "-Inf"
    fin <- is.finite(x)
    if (any(fin)) {
      short <- sprintf("%.15g", x[fin])
      exact <- as.numeric(short) == x[fin]
      whole <- x[fin] == trunc(x[fin])
      if (any(!exact & !whole)) {
        bad <- x[fin][!exact & !whole][1L]
        filter_error(
          expr,
          sprintf(
            "the double %s has no exact decimal form of 15 digits; write it as text, such as \"%s\", to compare it exactly",
            sprintf("%.17g", bad), sprintf("%.15g", bad)
          )
        )
      }
      out <- ifelse(exact, short, sprintf("%.0f", x[fin]))
      text[fin] <- out
    }
  } else {
    filter_error(expr, sprintf("a %s value cannot be compared with a number column", class(value)[1L]))
  }
  list(keys = exact_parse(text), nan = nan)
}

# Text is a date or a time on those columns only: against a boolean, float
# or double column R would compare the two as strings, so it is refused
# rather than read as a number (#73).
literal_number <- function(value, type, expr) {
  n <- length(value)
  if (is.character(value)) {
    x <- switch(type,
      date = as.numeric(unclass(parse_date_text(value))),
      timestamp = as.numeric(unclass(parse_time_text(value, zone = TRUE))),
      timestamp_ntz = as.numeric(unclass(parse_time_text(value, zone = FALSE))),
      rep(NA_real_, n)
    )
    bad <- !is.na(value) & is.na(x)
    if (any(bad) && type %in% c("float", "double")) {
      filter_error(
        expr,
        sprintf(
          "%s is text, which zulake does not compare with a %s column (R would compare them as strings); give a number",
          format_string(value[bad][1L]), type
        )
      )
    }
    if (any(bad)) {
      filter_error(expr, sprintf("%s is not a %s", format_string(value[bad][1L]), type))
    }
    return(list(keys = x, nan = rep(FALSE, n)))
  }
  if (type == "date" && inherits(value, "POSIXt") || type %in% c("timestamp", "timestamp_ntz") && inherits(value, "Date")) {
    filter_error(expr, sprintf("a %s value cannot be compared with a %s column", class(value)[1L], type))
  }
  if (!is.numeric(unclass(value)) && !is.logical(value)) {
    filter_error(expr, sprintf("a %s value cannot be compared with a %s column", class(value)[1L], type))
  }
  x <- if (inherits(value, "integer64")) as.numeric(as.character(value)) else as.numeric(unclass(value))
  list(keys = x, nan = is.nan(x))
}

# The values of a column (as a read or the partition values give them) as
# keys of `kind`: decimal text for "exact", doubles for "number", strings for
# "bytes". `type` gives a decimal's scale.
column_keys <- function(x, kind, type) {
  switch(kind,
    exact = exact_parse(column_exact_text(x, type)),
    number = as.numeric(unclass(x)),
    bytes = enc2utf8(as.character(x))
  )
}

column_exact_text <- function(x, type) {
  if (is.character(x)) {
    return(sub("^[+]", "", x))
  }
  if (inherits(x, "integer64")) {
    return(as.character(x))
  }
  out <- rep(NA_character_, length(x))
  have <- !is.na(x)
  ps <- decimal_ps(type)
  if (!is.null(ps)) {
    out[have] <- sprintf("%.*f", as.integer(ps[["scale"]]), as.numeric(x[have]))
  } else {
    out[have] <- sprintf("%.0f", as.numeric(x[have]))
  }
  out
}

# -1, 0 or 1 comparing keys of one kind, `b` recycled; NA where either is NA
# (or NaN).
keys_cmp <- function(a, b, kind) {
  switch(kind,
    exact = exact_cmp(a, b),
    number = {
      n <- max(length(a), length(b))
      if (!length(a) || !length(b)) {
        return(integer())
      }
      a <- rep_len(a, n)
      b <- rep_len(b, n)
      as.integer((a > b) - (a < b))
    },
    bytes = bytes_cmp(a, b)
  )
}

keys_length <- function(k) if (is.list(k)) length(k$sign) else length(k)

keys_subset <- function(k, i) if (is.list(k)) lapply(k, `[`, i) else k[i]

keys_na <- function(k) if (is.list(k)) is.na(k$sign) else is.na(k)

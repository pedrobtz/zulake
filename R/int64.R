# 64-bit integers from the log (design section 7, D10).
#
# zujson turns every JSON number into a double, so an integer past 2^53 - 1
# would round silently on the way in. Before parsing, number tokens are
# rewritten as strings that start with `num_mark`, so their digits survive:
# every number of a `stats` string (decimal statistics stay as their JSON
# text), and in a commit only integers past 2^53 - 1. The functions that
# return a value turn a marked string into a double when it is exact, and
# otherwise into an error or, with `int64 = "integer64"`, a bit64 integer64.

num_mark <- "\x1e"

# JSON text with number tokens rewritten as marked strings: every number when
# `all` is TRUE, otherwise only integers whose magnitude passes 2^53 - 1.
# Strings and numbers are matched whole, left to right, so digits inside a
# string, a fraction or an exponent are never taken for an integer.
mark_numbers <- function(text, all = FALSE) {
  if (!all) {
    hit <- grepl("[0-9]{16}", text)
    if (!any(hit)) {
      return(text)
    }
  }
  pattern <- paste0(
    "\"(?:[^\"\\\\]|\\\\.)*\"",
    "|-?[0-9]+(?:[.][0-9]+)?(?:[eE][+-]?[0-9]+)?"
  )
  m <- gregexpr(pattern, text, perl = TRUE)
  regmatches(text, m) <- lapply(regmatches(text, m), function(tok) {
    num <- !startsWith(tok, "\"")
    if (!all) {
      num <- num & integer_past_exact(tok)
    }
    tok[num] <- paste0("\"\\u001e", tok[num], "\"")
    tok
  })
  text
}

# Integer tokens whose magnitude is more than 2^53 - 1, decided on the digits.
integer_past_exact <- function(tok) {
  int <- grepl("^-?[0-9]+$", tok)
  digits <- sub("^-?0*", "", tok)
  limit <- sprintf("%.0f", max_exact)
  int & (nchar(digits) > nchar(limit) | (nchar(digits) == nchar(limit) & sorts_after(digits, limit)))
}

is_marked <- function(x) {
  is.character(x) && length(x) == 1L && !is.na(x) && startsWith(x, num_mark)
}

marked_text <- function(x) substring(x, 2L)

# A whole number as zujson left it: a double, or a marked integer.
is_whole_or_marked <- function(x) {
  is_whole(x) || (is_marked(x) && grepl("^-?[0-9]+$", marked_text(x)))
}

is_negative <- function(x) {
  if (is_marked(x)) startsWith(marked_text(x), "-") else x < 0
}

# A whole number written in full, for keys and messages.
int_text <- function(x) {
  if (is_marked(x)) marked_text(x) else format_number(x)
}

check_int64 <- function(int64) {
  if (!is.character(int64) || length(int64) < 1L || anyNA(int64)) {
    zulake_abort("argument", "`int64` must be \"double\" or \"integer64\".")
  }
  if (length(int64) > 1L) {
    int64 <- int64[1L]
  }
  if (!int64 %in% c("double", "integer64")) {
    zulake_abort("argument", "`int64` must be \"double\" or \"integer64\".")
  }
  if (int64 == "integer64" && !has_bit64()) {
    zulake_abort("argument", "`int64 = \"integer64\"` needs the bit64 package, which is not installed.")
  }
  int64
}

has_bit64 <- function() requireNamespace("bit64", quietly = TRUE)

# 64-bit integers (a list or vector of NULL, NA, numbers and marked strings)
# as a double vector, exact or an error, or as an integer64 vector. `what`
# names the values for the error message.
int64_values <- function(x, int64, what) {
  n <- length(x)
  if (!is.list(x)) {
    x <- as.list(x)
  }
  text <- rep(NA_character_, n)
  num <- rep(NA_real_, n)
  for (i in seq_len(n)) {
    v <- x[[i]]
    if (is.null(v) || (length(v) == 1L && is.atomic(v) && is.na(v))) next
    if (is_marked(v)) {
      text[i] <- marked_text(v)
    } else if (length(v) == 1L && is.numeric(v) && !inherits(v, "integer64")) {
      num[i] <- as.numeric(v)
    } else {
      zulake_abort("corrupt_log", sprintf("%s holds a value that is not a number.", what))
    }
  }
  have_num <- !is.na(num)
  if (any(have_num & (!is.finite(num) | num != trunc(num)))) {
    zulake_abort("corrupt_log", sprintf("%s holds a value that is not a whole number.", what))
  }
  have_text <- !is.na(text)
  if (any(have_text & !grepl("^-?[0-9]+$", text))) {
    zulake_abort("corrupt_log", sprintf("%s holds a value that is not a whole number.", what))
  }
  past <- (have_num & abs(num) > max_exact) | (have_text & integer_past_exact(text))
  small_text <- have_text & !past
  num[small_text] <- as.numeric(text[small_text])
  if (int64 == "double") {
    if (any(past)) {
      v <- if (have_text[past][1L]) text[past][1L] else format_number(num[past][1L])
      zulake_abort(
        "int64",
        sprintf(
          "%s holds %s, which a double cannot hold exactly (the limit is 2^53 - 1); use `int64 = \"integer64\"`.",
          what, v
        ),
        value = v
      )
    }
    return(num)
  }
  out <- rep(NA_character_, n)
  out[have_num | small_text] <- sprintf("%.0f", num[have_num | small_text])
  big <- past & have_text
  out[big] <- text[big]
  out[past & !have_text] <- sprintf("%.0f", num[past & !have_text])
  res <- suppressWarnings(bit64::as.integer64(out))
  if (any(!is.na(out) & is.na(res))) {
    v <- out[!is.na(out) & is.na(res)][1L]
    zulake_abort(
      "int64",
      sprintf("%s holds %s, outside what an integer64 holds (-2^63 + 1 to 2^63 - 1; bit64 keeps -2^63 for NA).", what, v),
      value = v
    )
  }
  res
}

# A sum of 64-bit counts, exact: an error when a double cannot hold it, unless
# `int64 = "integer64"`.
int64_sum <- function(x, int64, what) {
  if (int64 == "integer64") {
    return(sum(x))
  }
  total <- sum(x)
  if (!is.na(total) && total > max_exact) {
    zulake_abort(
      "int64",
      sprintf(
        "%s is %s or more, which a double cannot hold exactly (the limit is 2^53 - 1); use `int64 = \"integer64\"`.",
        what, format_number(total)
      ),
      value = format_number(total)
    )
  }
  total
}

# A parsed JSON value with every marked integer turned into a number: a
# double when exact, otherwise an error or an integer64 (`int64`).
unmark_tree <- function(x, int64, what) {
  if (is.list(x)) {
    if (!length(x)) {
      return(x)
    }
    keep <- attributes(x)
    out <- lapply(x, unmark_tree, int64 = int64, what = what)
    attributes(out) <- keep
    return(out)
  }
  if (is.character(x) && any(startsWith(x, num_mark), na.rm = TRUE)) {
    marked <- !is.na(x) & startsWith(x, num_mark)
    if (length(x) == 1L) {
      return(int64_values(x, int64, what))
    }
    vals <- lapply(x, function(v) if (!is.na(v) && startsWith(v, num_mark)) int64_values(v, int64, what) else v)
    if (all(marked)) {
      return(do.call(c, vals))
    }
    return(vals)
  }
  x
}

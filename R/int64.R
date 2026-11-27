# 64-bit integers from the log (design section 7, D10).
#
# zujson turns every JSON number into a double, so an integer past 2^53 - 1
# would round silently on the way in. Before parsing, number tokens are
# rewritten as strings that start with `num_mark`, so their digits survive:
# every number of a `stats` string (decimal statistics stay as their JSON
# text), and in a commit only integers past 2^53 - 1. A string of the text
# that itself starts with the mark gets a second one, and after parsing
# seal_marks() tells the two apart once: a marked number becomes a
# "zulake_int" object (its digits, classed), a string loses the mark it was
# given (#56). From there on a number is known by its class, never by its
# first character, so no string can be taken for one. The functions that
# return a value turn a marked number into a double when it is exact, and
# otherwise into an error or, with `int64 = "integer64"`, a bit64
# integer64.

num_mark <- "\x1e"

# The marked number holding the digits `text`.
make_marked <- function(text) structure(text, class = "zulake_int")

# JSON text with number tokens rewritten as marked strings: every number when
# `all` is TRUE, otherwise only integers whose magnitude passes 2^53 - 1.
# Strings and numbers are matched whole, left to right, so digits inside a
# string, a fraction or an exponent are never taken for an integer; a string
# that starts with U+001E is given a second one. The pattern's quantifiers
# are possessive, so a string of any length is matched without
# backtracking; should PCRE still fail, the failure is an error, never text
# left unmarked (#57).
mark_numbers <- function(text, all = FALSE) {
  if (!all) {
    hit <- grepl("[0-9]{16}", text) | grepl("\"\\\\u001[eE]", text)
    if (!any(hit)) {
      return(text)
    }
  }
  pattern <- paste0(
    "\"(?:[^\"\\\\]++|\\\\.)*+\"",
    "|-?[0-9]++(?:[.][0-9]++)?+(?:[eE][+-]?+[0-9]++)?+"
  )
  m <- withCallingHandlers(
    json_tokens(pattern, text),
    warning = function(w) {
      zulake_abort(
        "corrupt_log",
        sprintf(
          "the log's JSON could not be scanned for 64-bit integers: %s",
          conditionMessage(w)
        )
      )
    }
  )
  regmatches(text, m) <- lapply(regmatches(text, m), function(tok) {
    num <- !startsWith(tok, "\"")
    if (!all) {
      num <- num & integer_past_exact(tok)
    }
    tok[num] <- paste0("\"\\u001e", tok[num], "\"")
    str <- !num & grepl("^\"\\\\u001[eE]", tok)
    tok[str] <- paste0("\"\\u001e", substring(tok[str], 2L))
    tok
  })
  text
}

json_tokens <- function(pattern, text) gregexpr(pattern, text, perl = TRUE)

# A value zujson parsed from marked text (mark_numbers()) with its marks
# read: a string that starts with U+001E twice is a string, with one mark
# dropped; one that starts with it once is a marked number (make_marked()).
# An array holding numbers and strings becomes a list. Names are strings.
seal_marks <- function(x) {
  if (is.list(x)) {
    if (!length(x)) {
      return(x)
    }
    keep <- attributes(x)
    out <- lapply(x, seal_marks)
    attributes(out) <- keep
    nm <- names(out)
    if (!is.null(nm)) {
      esc <- startsWith(nm, "\x1e\x1e")
      if (any(esc)) {
        nm[esc] <- substring(nm[esc], 2L)
        names(out) <- nm
      }
    }
    return(out)
  }
  if (!is.character(x)) {
    return(x)
  }
  m <- !is.na(x) & startsWith(x, num_mark)
  if (!any(m)) {
    return(x)
  }
  esc <- m & startsWith(x, "\x1e\x1e")
  num <- m & !esc
  x[esc] <- substring(x[esc], 2L)
  if (!any(num)) {
    return(x)
  }
  if (all(num)) {
    return(make_marked(substring(x, 2L)))
  }
  lapply(seq_along(x), function(i) {
    if (num[i]) make_marked(substring(x[i], 2L)) else x[i]
  })
}

# Text parsed as JSON with its numbers marked, as a commit's line is.
parse_marked <- function(text, all = FALSE) {
  seal_marks(zujson::json_parse(mark_numbers(text, all = all)))
}

# Integer tokens whose magnitude is more than 2^53 - 1, decided on the digits.
integer_past_exact <- function(tok) {
  int <- grepl("^-?[0-9]+$", tok)
  digits <- sub("^-?0*", "", tok)
  limit <- sprintf("%.0f", max_exact)
  int &
    (nchar(digits) > nchar(limit) |
      (nchar(digits) == nchar(limit) & sorts_after(digits, limit)))
}

is_marked <- function(x) {
  inherits(x, "zulake_int") && length(x) == 1L && !is.na(x)
}

marked_text <- function(x) as.character(unclass(x))

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
    zulake_abort(
      "argument",
      "`int64 = \"integer64\"` needs the bit64 package, which is not installed."
    )
  }
  int64
}

has_bit64 <- function() requireNamespace("bit64", quietly = TRUE)

# 64-bit integers (a list or vector of NULL, NA, numbers and marked strings)
# as a double vector, exact or an error, or as an integer64 vector. `what`
# names the values for the error message.
int64_values <- function(x, int64, what) {
  n <- length(x)
  if (inherits(x, "zulake_int")) {
    x <- lapply(unclass(x), make_marked)
  }
  if (!is.list(x)) {
    x <- as.list(x)
  }
  text <- rep(NA_character_, n)
  num <- rep(NA_real_, n)
  for (i in seq_len(n)) {
    v <- x[[i]]
    if (is.null(v) || (length(v) == 1L && is.atomic(v) && is.na(v))) {
      next
    }
    if (is_marked(v)) {
      text[i] <- marked_text(v)
    } else if (length(v) == 1L && is.numeric(v) && !inherits(v, "integer64")) {
      num[i] <- as.numeric(v)
    } else {
      zulake_abort(
        "corrupt_log",
        sprintf("%s holds a value that is not a number.", what)
      )
    }
  }
  have_num <- !is.na(num)
  if (any(have_num & (!is.finite(num) | num != trunc(num)))) {
    zulake_abort(
      "corrupt_log",
      sprintf("%s holds a value that is not a whole number.", what)
    )
  }
  have_text <- !is.na(text)
  if (any(have_text & !grepl("^-?[0-9]+$", text))) {
    zulake_abort(
      "corrupt_log",
      sprintf("%s holds a value that is not a whole number.", what)
    )
  }
  past <- (have_num & abs(num) > max_exact) |
    (have_text & integer_past_exact(text))
  small_text <- have_text & !past
  num[small_text] <- as.numeric(text[small_text])
  if (int64 == "double") {
    if (any(past)) {
      v <- if (have_text[past][1L]) {
        text[past][1L]
      } else {
        format_number(num[past][1L])
      }
      zulake_abort(
        "int64",
        sprintf(
          paste(
            "%s holds %s, which a double cannot hold exactly (the limit is 2^53 -",
            "1); use `int64 = \"integer64\"`."
          ),
          what,
          v
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
      sprintf(
        paste(
          "%s holds %s, outside what an integer64 holds (-2^63 + 1 to 2^63 - 1;",
          "bit64 keeps -2^63 for NA)."
        ),
        what,
        v
      ),
      value = v
    )
  }
  res
}

# A sum of 64-bit counts, exact: an error when a double cannot hold it, unless
# `int64 = "integer64"`.
int64_sum <- function(x, int64, what) {
  if (int64 == "integer64") {
    # bit64 gives NA, with a warning, for a sum past 2^63 - 1 (#92).
    over <- FALSE
    total <- withCallingHandlers(sum(x), warning = function(w) {
      if (grepl("overflow", conditionMessage(w), fixed = TRUE)) {
        over <<- TRUE
        invokeRestart("muffleWarning")
      }
    })
    if (over || (is.na(total) && !anyNA(x))) {
      zulake_abort(
        "int64",
        sprintf("%s is more than 2^63 - 1, which integer64 cannot hold.", what),
        value = NA_character_
      )
    }
    return(total)
  }
  total <- sum(x)
  if (!is.na(total) && total > max_exact) {
    zulake_abort(
      "int64",
      sprintf(
        paste(
          "%s is %s or more, which a double cannot hold exactly (the limit is",
          "2^53 - 1); use `int64 = \"integer64\"`."
        ),
        what,
        format_number(total)
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
  if (inherits(x, "zulake_int")) {
    return(int64_values(x, int64, what))
  }
  x
}

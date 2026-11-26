# Helpers for the read tests (test-read.R, test-filter.R). Here, not in a
# test file, because the suite shuffles every top-level expression of a test
# file.

# Every (table, version) of inspect_cases(), which this version reads; those
# with live deletion vectors only when zuroar is installed (the nosuggests
# check has none; test-dv.R tests the error).
read_cases <- function() {
  if (requireNamespace("zuroar", quietly = TRUE)) {
    return(inspect_cases())
  }
  Filter(function(case) {
    tbl <- case_snapshot(case)
    all(vapply(tbl$files$action, function(a) is.null(a[["deletionVector"]]), NA))
  }, inspect_cases())
}

# A read with every warning collected: list(value, warnings).
collect_warnings <- function(expr) {
  warnings <- list()
  value <- withCallingHandlers(expr, warning = function(w) {
    warnings[[length(warnings) + 1L]] <<- w
    invokeRestart("muffleWarning")
  })
  list(value = value, warnings = warnings)
}

# deltalake's full read of `table` at `version` as canonical columns, with
# the differences qio documents (design section 8): an int32 of -2^31 and a
# 64-bit value outside what `int64` holds read as NA, a decimal as the
# nearest double, a float as the double of its float.
oracle_read_columns <- function(table, version, int64 = "double") {
  ans <- oracle_field(table, version, "read")
  types <- stats::setNames(vapply(ans$schema, function(s) s$type, ""), vapply(ans$schema, function(s) s$name, ""))
  out <- list()
  for (col in names(ans$columns)) {
    tokens <- oracle_canon_column(ans$columns[[col]])
    type <- types[[col]]
    text <- vapply(tokens, function(t) if (is.character(t) && length(t) == 1L) t else NA_character_, "")
    null <- text %in% "null"
    if (startsWith(type, "decimal128")) {
      tokens[!null] <- as.list(oracle_tokens(as.numeric(text[!null])))
    } else if (type == "int32") {
      tokens[text %in% "-2147483648"] <- list("null")
    } else if (type == "int64") {
      digits <- sub("^-", "", text)
      big <- !null & (nchar(digits) > 16 | (nchar(digits) == 16 & digits > "9007199254740992"))
      drop <- if (int64 == "double") big else text %in% "-9223372036854775808"
      tokens[drop] <- list("null")
    } else if (type == "float") {
      num <- text
      num[num == "Infinity"] <- "Inf"
      num[num == "-Infinity"] <- "-Inf"
      x <- as.numeric(num[!null])
      fin <- is.finite(x)
      x[fin] <- readBin(writeBin(x[fin], raw(), size = 4L), "double", n = sum(fin), size = 4L)
      tokens[!null] <- as.list(oracle_tokens(x))
    }
    out[[col]] <- tokens
  }
  out
}

# Expect `actual`, a read, to equal deltalake's full read (rows in any
# order), in the columns `actual` has; `skipped` are the answer's columns
# `actual` must not have.
expect_read_oracle <- function(actual, table, version, int64 = "double", skipped = character()) {
  label <- paste(deparse(substitute(actual)), collapse = "")
  expected <- oracle_read_columns(table, version, int64)
  testthat::expect_setequal(names(actual), setdiff(names(expected), skipped))
  act <- oracle_sort_rows(oracle_canon(actual))
  exp <- expected[names(actual)]
  exp <- oracle_sort_rows(exp[order(names(exp), method = "radix")])
  testthat::expect_identical(act, exp, label = label,
                             expected.label = sprintf("deltalake's read of %s at version %s", table, version))
  invisible(actual)
}

# ---- random filters over rows ----------------------------------------------

# A random filter over the columns of `data` (a full read), of depth at most
# 3, with values taken from the data, nudged, or missing.
random_row_filter <- function(data, depth = 0L) {
  if (depth < 3L && stats::runif(1) < 0.4) {
    op <- sample(c("&", "|", "!"), 1L)
    if (op == "!") {
      return(call("!", random_row_filter(data, depth + 1L)))
    }
    return(call(op, random_row_filter(data, depth + 1L), random_row_filter(data, depth + 1L)))
  }
  if (stats::runif(1) < 0.3) {
    return(random_row_wise(data))
  }
  col <- sample(names(data), 1L)
  values <- data[[col]]
  sym <- as.symbol(col)
  op <- sample(filter_atom_calls, 1L, prob = c(3, 2, 2, 2, 2, 2, 2, 1))
  if (op == "is.na") {
    return(call("is.na", sym))
  }
  pick <- function() {
    pool <- unique(values[!is.na(values)])
    if (!length(pool) || stats::runif(1) < 0.05) {
      return(values[NA_integer_])
    }
    v <- pool[sample.int(length(pool), 1L)]
    if (is.character(v) && nchar(v) > 1L && stats::runif(1) < 0.3) {
      v <- substr(v, 1L, sample.int(nchar(v) - 1L, 1L))
    } else if (is.numeric(v) && !inherits(v, "integer64") && is.finite(v) && stats::runif(1) < 0.3) {
      v <- v + sample(c(-1, -0.5, 0.5, 1), 1L)
    }
    v
  }
  if (op == "%in%") {
    set <- do.call(c, lapply(seq_len(sample(1:3, 1L)), function(i) pick()))
    if (stats::runif(1) < 0.2) set <- c(set, values[NA_integer_])
    return(call("%in%", sym, set))
  }
  v <- pick()
  if (stats::runif(1) < 0.2) call(op, v, sym) else call(op, sym, v)
}

# A random comparison outside the pruning subset, from the row-wise
# functions of design section 5 (D8) applied to a column of `data`, or two
# columns of one class compared. Values come from the data through the same
# function, so that some rows match.
random_row_wise <- function(data) {
  cls <- vapply(data, function(x) class(x)[1L], "")
  pick_col <- function(classes) {
    ok <- names(data)[cls %in% classes]
    if (length(ok)) ok[sample.int(length(ok), 1L)] else NA_character_
  }
  pick_value <- function(x) {
    x <- x[!is.na(x)]
    if (!length(x)) return(NA)
    x[sample.int(length(x), 1L)]
  }
  op <- function() sample(c("==", "!=", "<", "<=", ">", ">="), 1L)
  kind <- sample(c("number", "string", "time", "two", "logical"), 1L)
  num <- pick_col(c("numeric", "integer"))
  str <- pick_col("character")
  if (kind == "number" && !is.na(num)) {
    sym <- as.symbol(num)
    f <- sample(list(
      quote(abs(.x)), quote(.x + 1), quote(.x - 2.5), quote(.x * 2), quote(.x / 4), quote(.x %% 3),
      quote(.x %/% 2), quote(.x^2), quote(round(.x)), quote(round(.x, 1)), quote(floor(.x)),
      quote(ceiling(.x)), quote(sqrt(abs(.x))), quote(exp(.x / 1e6)), quote(log(abs(.x) + 1)),
      quote(-.x), quote(as.integer(.x %% 1000)), quote(nchar(as.character(.x)))
    ), 1L)[[1L]]
    e <- do.call(substitute, list(f, list(.x = sym)))
    if (stats::runif(1) < 0.15) {
      return(sample(list(bquote(is.finite(.(e))), bquote(is.nan(.(e)))), 1L)[[1L]])
    }
    v <- pick_value(suppressWarnings(eval(e, as.list(data), baseenv())))
    return(call(op(), e, v))
  }
  if (kind == "string" && !is.na(str)) {
    sym <- as.symbol(str)
    x <- pick_value(data[[str]])
    if (is.na(x)) x <- "a"
    pre <- substr(x, 1L, max(1L, nchar(x) %/% 2L))
    return(sample(list(
      bquote(nchar(.(sym)) > .(nchar(x) - 1L)),
      bquote(toupper(.(sym)) == .(toupper(x))),
      bquote(tolower(.(sym)) != .(tolower(x))),
      bquote(substr(.(sym), 1, 2) == .(substr(x, 1L, 2L))),
      bquote(startsWith(.(sym), .(pre))),
      bquote(endsWith(.(sym), .(substring(x, nchar(x))))),
      bquote(grepl(.(pre), .(sym), fixed = TRUE)),
      bquote(as.character(.(sym)) %in% .(c(x, "zzz"))),
      bquote(xor(is.na(.(sym)), nchar(.(sym)) > 1))
    ), 1L)[[1L]])
  }
  if (kind == "time") {
    tcol <- pick_col(c("Date", "POSIXct"))
    if (!is.na(tcol)) {
      sym <- as.symbol(tcol)
      v <- pick_value(as.numeric(data[[tcol]]))
      return(call(op(), bquote(as.numeric(.(sym))), v))
    }
  }
  if (kind == "two") {
    for (classes in sample(list(c("numeric", "integer"), "character", "Date", "POSIXct"))) {
      both <- names(data)[cls %in% classes]
      if (length(both) >= 2L) {
        two <- sample(both, 2L)
        return(call(op(), as.symbol(two[1L]), as.symbol(two[2L])))
      }
    }
  }
  if (kind == "logical") {
    lcol <- pick_col("logical")
    if (!is.na(lcol)) {
      return(bquote(xor(.(as.symbol(lcol)), TRUE)))
    }
  }
  col <- names(data)[sample.int(length(data), 1L)]
  bquote(is.na(as.character(.(as.symbol(col)))))
}

# A table of the rows of `data` (a data frame of double, integer,
# character, Date and logical columns) written as `k` Parquet files with qio,
# the rows split in order at random points, and a log by hand with no
# statistics. Partition columns are none.
split_table <- function(data, k, env = parent.frame()) {
  delta <- c(numeric = "double", integer = "integer", character = "string", Date = "date", logical = "boolean")
  types <- delta[vapply(data, function(x) class(x)[1L], "")]
  names(types) <- names(data)
  path <- file.path(withr::local_tempdir(.local_envir = env), "table")
  dir.create(path)
  n <- nrow(data)
  cuts <- sort(sample(seq_len(n - 1L), k - 1L))
  group <- findInterval(seq_len(n), cuts + 1L)
  adds <- character()
  for (g in sort(unique(group))) {
    file <- sprintf("part-%05d.parquet", g)
    qio::write_parquet(data[group == g, , drop = FALSE], file.path(path, file))
    adds <- c(adds, add_line(file, size = file.size(file.path(path, file))))
  }
  write_commit(path, 0, c(protocol_line(), metadata_line(types), adds))
  path
}

# The rows of `data` for which R makes `expr` TRUE (in the C collation, so
# that strings compare in byte order, as zulake's filters do).
r_subset <- function(data, expr) {
  keep <- eval(expr, as.list(data), baseenv())
  keep <- rep_len(keep, nrow(data)) %in% TRUE
  structure(lapply(data, function(x) x[keep]), class = "data.frame", row.names = .set_row_names(sum(keep)))
}

# Every live file's rows of a snapshot, unfiltered: list of pieces, by file.
read_each_file <- function(tbl, int64 = "double") {
  scan <- read_scan(tbl, NULL, NULL, globalenv(), int64)
  lapply(seq_along(scan$keep), function(k) read_piece(scan, k))
}

# A storage backend with no local paths, so data files come through get()
# and the session cache, recording each get() in `env$calls`.
remote_storage <- function(storage, env) {
  wrapped <- recording_storage(storage, env)
  wrapped$local_path <- NULL
  wrapped$kind <- "test"
  wrapped
}

# ---- exact comparison, a second way --------------------------------------------

# Random decimal text: a sign, digits with leading zeros, a fraction with
# trailing zeros, an exponent in one of its spellings.
random_decimal_text <- function() {
  digits <- function(n) paste(sample(0:9, n, replace = TRUE), collapse = "")
  sign <- sample(c("", "", "-", "+"), 1L)
  int <- digits(sample(1:22, 1L))
  if (stats::runif(1) < 0.3) int <- paste0("000", int)
  frac <- if (stats::runif(1) < 0.6) paste0(".", digits(sample(1:20, 1L)), if (stats::runif(1) < 0.3) "000") else ""
  exp <- if (stats::runif(1) < 0.3) paste0(sample(c("e", "E"), 1L), sample(c("", "+", "-"), 1L), sample(0:12, 1L)) else ""
  if (stats::runif(1) < 0.05) return(paste0(sign, "0", if (nzchar(frac)) ".000"))
  paste0(sign, int, frac, exp)
}

# -1, 0 or 1 comparing two decimal texts by writing both out in full, with
# the exponent applied by moving the point, padded to the same width, and
# compared character by character.
reference_cmp <- function(a, b) {
  full <- function(x) {
    m <- regmatches(x, regexec("^([+-]?)([0-9]+)(?:[.]([0-9]+))?(?:[eE]([+-]?[0-9]+))?$", x))[[1L]]
    neg <- m[2L] == "-"
    int <- m[3L]
    frac <- m[4L]
    e <- if (nzchar(m[5L])) as.integer(m[5L]) else 0L
    if (e > 0) {
      frac <- paste0(frac, strrep("0", e))
      int <- paste0(int, substr(frac, 1L, e))
      frac <- substring(frac, e + 1L)
    } else if (e < 0) {
      int <- paste0(strrep("0", -e), int)
      frac <- paste0(substring(int, nchar(int) + e + 1L), frac)
      int <- substr(int, 1L, nchar(int) + e)
    }
    int <- sub("^0+", "", int)
    frac <- sub("0+$", "", frac)
    list(neg = neg && nzchar(paste0(int, frac)), int = int, frac = frac)
  }
  x <- full(a)
  y <- full(b)
  zero_x <- !nzchar(paste0(x$int, x$frac))
  zero_y <- !nzchar(paste0(y$int, y$frac))
  sx <- if (zero_x) 0L else if (x$neg) -1L else 1L
  sy <- if (zero_y) 0L else if (y$neg) -1L else 1L
  if (sx != sy) return(as.integer(sign(sx - sy)))
  if (sx == 0L) return(0L)
  w <- max(nchar(x$int), nchar(y$int))
  f <- max(nchar(x$frac), nchar(y$frac))
  pad <- function(p) paste0(strrep("0", w - nchar(p$int)), p$int, p$frac, strrep("0", f - nchar(p$frac)))
  px <- strsplit(pad(x), "")[[1L]]
  py <- strsplit(pad(y), "")[[1L]]
  d <- which(px != py)
  if (!length(d)) return(0L)
  sx * (if (px[d[1L]] > py[d[1L]]) 1L else -1L)
}

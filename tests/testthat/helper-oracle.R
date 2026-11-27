# The fixture corpus and deltalake 1.7.0's answers for it.
#
# Tables and hostile logs ship packed in fixtures/delta-fixtures.tar (their
# paths are too long for a package tarball); fixture_dir() unpacks it once per
# session. Answers are fixtures/answers/<table>/<version>.json, written by
# tools/oracle/answers.py; tools/oracle/README.md gives their fields and
# encoding. Helpers live here, not in a test file, because the suite shuffles
# every top-level expression of a test file.

oracle_env <- new.env(parent = emptyenv())

# Directory holding the unpacked `tables/` and `hostile/` trees.
fixture_dir <- function() {
  if (is.null(oracle_env$dir) || !dir.exists(oracle_env$dir)) {
    tar <- testthat::test_path("fixtures", "delta-fixtures.tar")
    if (!file.exists(tar)) {
      stop("fixtures/delta-fixtures.tar is missing", call. = FALSE)
    }
    dir <- tempfile("zulake-fixtures-")
    dir.create(dir)
    utils::untar(tar, exdir = dir, tar = "internal")
    oracle_env$dir <- normalizePath(dir, winslash = "/")
  }
  oracle_env$dir
}

# Names of the fixture tables (`kind = "tables"`) or hostile logs.
fixture_names <- function(kind = c("tables", "hostile")) {
  kind <- match.arg(kind)
  sort(list.files(file.path(fixture_dir(), kind)))
}

# Path of one fixture table, or of one hostile log with `kind = "hostile"`.
# Treat it as read-only: it is shared by the whole session.
fixture_table <- function(name, kind = c("tables", "hostile")) {
  kind <- match.arg(kind)
  path <- file.path(fixture_dir(), kind, name)
  if (length(name) != 1L || !dir.exists(path)) {
    stop("no fixture ", kind, "/", name, call. = FALSE)
  }
  path
}

# A private copy of a fixture under a temporary directory removed when `env`
# ends, for a test that changes files.
local_fixture_copy <- function(name, kind = c("tables", "hostile"), env = parent.frame()) {
  kind <- match.arg(kind)
  src <- fixture_table(name, kind)
  dest <- withr::local_tempdir(.local_envir = env)
  stopifnot(file.copy(src, dest, recursive = TRUE, copy.date = TRUE))
  file.path(dest, name)
}

# Versions a table's `_delta_log/` records: every commit and checkpoint.
fixture_log_versions <- function(path) {
  files <- list.files(file.path(path, "_delta_log"))
  commit <- "^([0-9]{20})[.]json$"
  checkpoint <- paste0(
    "^([0-9]{20})[.]checkpoint",
    "([.][0-9]{10}[.][0-9]{10}|[.][0-9a-f-]{36})?[.](parquet|json)$"
  )
  hit <- grepl(commit, files) | grepl(checkpoint, files)
  sort(unique(as.numeric(substr(files[hit], 1L, 20L))))
}

oracle_answers_dir <- function() {
  if (!is.null(oracle_env$answers_dir)) {
    return(oracle_env$answers_dir)
  }
  testthat::test_path("fixtures", "answers")
}

# Answers from `dir` instead, until `env` ends: deltalake's answers for the
# tables on Azurite (test-azure-emulator.R, tools/oracle/azurite.py).
local_oracle_answers <- function(dir, env = parent.frame()) {
  old <- oracle_env$answers_dir
  oracle_env$answers_dir <- dir
  withr::defer(oracle_env$answers_dir <- old, envir = env)
  invisible(dir)
}

# Versions with an answer file, as doubles, ascending.
oracle_versions <- function(table) {
  files <- list.files(file.path(oracle_answers_dir(), table), pattern = "^[0-9]+[.]json$")
  sort(as.numeric(sub("[.]json$", "", files)))
}

# The whole answer file for `table` at `version`, parsed by zujson.
oracle_answer <- function(table, version) {
  path <- file.path(oracle_answers_dir(), table, paste0(format(version, scientific = FALSE), ".json"))
  if (!file.exists(path)) {
    stop("no deltalake answer for ", table, " at version ", version, call. = FALSE)
  }
  key <- paste(oracle_answers_dir(), table, version)
  if (is.null(oracle_env$answers[[key]])) {
    if (is.null(oracle_env$answers)) oracle_env$answers <- list()
    oracle_env$answers[[key]] <- zujson::json_parse_file(path)
  }
  oracle_env$answers[[key]]
}

# One field of an answer. `field` is a path: "count", c("protocol",
# "reader_features"), c("read", "columns", "id"). A field deltalake failed to
# answer holds list(error = list(class =, message =)).
oracle_field <- function(table, version, field) {
  x <- oracle_answer(table, version)
  for (f in field) {
    if (!is.list(x) || !f %in% names(x)) {
      stop("answer for ", table, " at version ", version, " has no field ",
           paste(field, collapse = "$"), call. = FALSE)
    }
    x <- x[[f]]
  }
  x
}

# deltalake's refusal to open `table` at `version` (list(class, message)), or
# NULL when it opened it.
oracle_refusal <- function(table, version) {
  oracle_answer(table, version)$refusal
}

# deltalake's refusal of the hostile log `name` at its last version
# (list(class, message), fixtures/hostile-answers.json), or NULL when it
# opened and read it.
hostile_refusal <- function(name) {
  if (is.null(oracle_env$hostile)) {
    oracle_env$hostile <- zujson::json_parse_file(testthat::test_path("fixtures", "hostile-answers.json"))
  }
  if (!name %in% names(oracle_env$hostile)) {
    stop("no deltalake answer for hostile log ", name, call. = FALSE)
  }
  oracle_env$hostile[[name]]$refusal
}

# ---- comparison ------------------------------------------------------------

# A value in canonical form: every scalar as text, so that a double, an
# integer, a bit64 integer64 and the answer's string for an int64 compare by
# value. Doubles are written exactly (whole numbers in full, others to 17
# significant digits), NaN and infinities by name, dates as YYYY-MM-DD,
# POSIXct to the microsecond with no zone mark, raw as hex, NA and NULL as
# "null". Named lists are sorted by name, since answer objects are.
oracle_canon <- function(x) {
  if (is.null(x)) {
    return("null")
  }
  if (is.raw(x)) {
    return(paste(as.character(x), collapse = ""))
  }
  if (is.data.frame(x)) {
    out <- lapply(x, oracle_canon_column)
    return(out[order(names(out), method = "radix")])
  }
  if (is.list(x)) {
    out <- lapply(x, oracle_canon)
    nm <- names(x)
    if (!is.null(nm) && all(nzchar(nm))) {
      out <- out[order(nm, method = "radix")]
    }
    return(out)
  }
  tokens <- oracle_tokens(x)
  if (length(tokens) == 1L && is.null(names(x))) {
    return(tokens)
  }
  out <- as.list(tokens)
  if (!is.null(names(x))) {
    names(out) <- names(x)
    out <- out[order(names(x), method = "radix")]
  }
  out
}

# A column, element by element, whatever its length.
oracle_canon_column <- function(x) {
  if (is.list(x)) unname(lapply(x, oracle_canon)) else as.list(unname(oracle_tokens(x)))
}

oracle_tokens <- function(x) {
  if (inherits(x, "factor")) {
    x <- as.character(x)
  }
  if (inherits(x, "integer64")) {
    out <- as.character(x)
  } else if (inherits(x, "POSIXct")) {
    out <- oracle_posixct_text(x)
  } else if (inherits(x, "Date")) {
    out <- oracle_date_text(as.numeric(unclass(x)))
  } else if (is.double(x)) {
    out <- rep(NA_character_, length(x))
    fin <- is.finite(x)
    whole <- fin & x == trunc(x) & abs(x) < 1e21
    out[whole] <- sprintf("%.0f", x[whole])
    out[whole & x == 0 & 1 / x < 0] <- "-0"
    # chartr(): the C library's decimal point is "," under a comma
    # LC_NUMERIC (#114).
    out[fin & !whole] <- chartr(",", ".", sprintf("%.17g", x[fin & !whole]))
    out[is.nan(x)] <- "NaN"
    out[x %in% Inf] <- "Infinity"
    out[x %in% -Inf] <- "-Infinity"
  } else if (is.logical(x)) {
    out <- ifelse(x, "true", "false")
  } else if (is.integer(x)) {
    out <- as.character(x)
  } else if (is.character(x)) {
    out <- enc2utf8(x)
    iso <- !is.na(out) & grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$", out)
    out[iso] <- sub("Z$", "", out[iso])
  } else {
    stop("oracle_canon(): no canonical form for ", class(x)[1L], call. = FALSE)
  }
  out[is.na(x) & !is.nan(x)] <- "null"
  out
}

# Days since 1970-01-01 as proleptic Gregorian YYYY-MM-DD, for any year 1-9999.
oracle_date_text <- function(days) {
  out <- rep(NA_character_, length(days))
  ok <- !is.na(days)
  lt <- as.POSIXlt(as.Date(days[ok], origin = "1970-01-01"), tz = "UTC")
  out[ok] <- sprintf("%04d-%02d-%02d", lt$year + 1900L, lt$mon + 1L, lt$mday)
  out
}

oracle_posixct_text <- function(x) {
  us <- round(as.numeric(unclass(x)) * 1e6)
  out <- rep(NA_character_, length(us))
  ok <- !is.na(us)
  day_us <- 86400 * 1e6
  days <- floor(us[ok] / day_us)
  rest <- us[ok] - days * day_us
  secs <- floor(rest / 1e6)
  out[ok] <- sprintf(
    "%sT%02d:%02d:%02d.%06d",
    oracle_date_text(days), secs %/% 3600, (secs %% 3600) %/% 60, secs %% 60,
    as.integer(rest - secs * 1e6)
  )
  out
}

oracle_is_table <- function(x) {
  is.list(x) && all(c("schema", "num_rows", "columns") %in% names(x))
}

# Rows of a canonical table (a named list of columns) as sortable keys.
oracle_row_keys <- function(cols) {
  n <- if (length(cols)) length(cols[[1L]]) else 0L
  vapply(seq_len(n), function(i) {
    paste(vapply(cols, function(col) {
      paste(names(unlist(col[[i]])), unlist(col[[i]]), sep = "=", collapse = "\x1e")
    }, ""), collapse = "\x1f")
  }, "")
}

oracle_sort_rows <- function(cols) {
  ord <- order(oracle_row_keys(cols), method = "radix")
  lapply(cols, function(col) col[ord])
}

# Expect `actual` to equal deltalake's answer for `field` of `table` at
# `version`, value for value (see oracle_canon()).
#
# When the answer is a table (a full read, the add actions), `actual` is a
# data frame: its columns are compared with the answer's columns of the same
# names, and rows in any order. A column `actual` lacks is not compared; a
# column the answer lacks fails.
expect_oracle <- function(actual, table, version, field) {
  label <- paste(deparse(substitute(actual)), collapse = "")
  expected <- oracle_field(table, version, field)
  what <- sprintf("deltalake's %s for %s at version %s", paste(field, collapse = "$"), table, version)
  if (oracle_is_table(expected) && is.data.frame(actual)) {
    extra <- setdiff(names(actual), names(expected$columns))
    if (length(extra)) {
      testthat::fail(sprintf("%s has columns %s that %s does not have",
                             label, paste(extra, collapse = ", "), what))
      return(invisible(actual))
    }
    act <- oracle_sort_rows(oracle_canon(actual))
    exp_cols <- lapply(expected$columns[names(actual)], oracle_canon_column)
    exp <- oracle_sort_rows(exp_cols[order(names(exp_cols), method = "radix")])
  } else {
    act <- oracle_canon(actual)
    exp <- oracle_canon(expected)
  }
  testthat::expect_identical(act, exp, label = label, expected.label = what)
  invisible(actual)
}

# The answer's table as a data frame of its canonical columns, for tests that
# build an `actual` from the answer itself.
oracle_table_frame <- function(x) {
  cols <- lapply(x$columns, function(col) if (is.list(col)) I(col) else col)
  structure(cols, class = "data.frame", row.names = seq_len(x$num_rows))
}

# The example table the package ships, which the README, the vignette and the
# examples open: inst/extdata/orders, a copy of the zl-orders fixture
# (tools/fixtures/pack.py writes it).
shipped_orders <- function() {
  system.file("extdata", "orders", package = "zulake", mustWork = TRUE)
}

# The code each help page's examples run, as R CMD check runs it (`\dontrun`
# commented out), by topic: from man/ in a source tree, else from the
# installed package.
example_code <- function() {
  man <- testthat::test_path("..", "..", "man")
  db <- if (dir.exists(man)) tools::Rd_db(dir = dirname(man)) else tools::Rd_db("zulake")
  lapply(db, function(rd) {
    out <- tempfile(fileext = ".R")
    on.exit(unlink(out))
    tools::Rd2ex(rd, out, commentDontrun = TRUE)
    lines <- if (file.exists(out)) readLines(out, warn = FALSE) else character()
    lines[!grepl("^\\s*#", lines)]
  })
}

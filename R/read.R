#' Read a table's rows
#'
#' `lake_read()` returns the rows of a snapshot as a data frame. It prunes
#' the live files with `filter` first, so that only the files whose rows
#' could match are read, then reads each one with qio, adds the partition
#' columns from the log, keeps the rows `filter` is `TRUE` for, and binds the
#' pieces. `lake_walk()` does the same one file at a time and calls `FUN` on
#' each piece instead of binding them, for tables larger than memory (but on
#' Azure not larger than disk; see below).
#'
#' `filter` is an unevaluated R expression over column names, with values
#' from the calling environment (a column's name always means the column).
#' Its pruning subset is comparisons (`==`, `!=`, `<`, `<=`, `>`, `>=`),
#' `%in%` and `is.na()` between a column and values, joined by `!`, `&` and
#' `|`. That subset rules files out by their partition values and their
#' statistics (minimum, maximum, null count and record count). Statistics
#' only decide what is read: the rows returned are the rows `filter` is
#' `TRUE` for whatever the statistics say, and a missing statistic only
#' means a file is read. On a column returned as a list (a `binary`
#' column), `is.na()` is `TRUE` where the value is null (`NULL`), as Delta
#' means it, where base R's `is.na()` on a list is `FALSE`.
#'
#' A filter may also apply these row-wise functions to columns: `+`, `-`,
#' `*`, `/`, `%%`, `%/%`, `^`, `abs()`, `round()`, `floor()`, `ceiling()`,
#' `sqrt()`, `exp()`, `log()`, `nchar()`, `toupper()`, `tolower()`,
#' `substr()`, `startsWith()`, `endsWith()`, `grepl()`, `is.nan()`,
#' `is.finite()`, `xor()`, `as.character()`, `as.numeric()` and
#' `as.integer()`; and compare two columns, or use a logical column alone.
#' R evaluates those on the rows after reading (they never prune), with base
#' R's functions whatever the caller defines, and each must give one `TRUE`,
#' `FALSE` or `NA` per row. Before R 4.3.0, `as.character()`, `substr()`,
#' `toupper()`, `tolower()` and `grepl()` of a `timestamp` or
#' `timestamp_ntz` column are errors of class `zulake_error_filter`, since
#' there a time's text depends on the other times formatted with it. Any
#' other call with a column inside it, such as
#' `max(x)`, `mean(x)`, `rank(x)`, `cumsum(x)`, `duplicated(x)`, `x[1]`,
#' `%in%` with a column on its right, or a function of your own, is an error
#' of class `zulake_error_filter`: a filter is decided row by row, so the
#' rows it keeps do not depend on how the table's rows are split into files,
#' and `lake_read()` equals the pieces of `lake_walk()` bound together. A
#' part of the filter that names no column is a value, evaluated once where
#' `lake_read()` is called, and may be any R expression.
#'
#' Inside the pruning subset, comparisons are exact: a `long`, `integer`,
#' `short`, `byte` or `decimal` column is compared with the value as decimal
#' numbers, digit by digit, and a `string` column in UTF-8 byte order
#' whatever the session's collation, as the table's statistics are. A value
#' given as text, such as `"12.30"`, is read as that decimal number; a double
#' that is not the number its 15-digit form reads back as (`1/3`,
#' `0.1 + 0.2`) is an error asking for the value as text. R has already
#' rounded a literal such as `9007199254740993` to a double
#' (9007199254740992) before zulake sees it, so give such a value as text
#' too. A `float` or `double` column takes
#' only numbers: text there, such as `amount > "100"`, is an error, since R
#' would compare it with the column as strings. A date or timestamp column takes a
#' `Date` or `POSIXct`, or text such as `"2024-01-31"` or
#' `"2024-01-31 12:00:00"` (UTC unless it gives an offset).
#'
#' Columns are typed as qio returns them (see [qio::read_parquet()]), and
#' partition columns as [lake_files()] types them, except that a `decimal`
#' of precision 15 or less, data or partition, is a double, which holds it
#' exactly. An `integer` data value of -2^31 reads as `NA`, R's integer
#' `NA`, with a warning from qio: `is.na()` is `TRUE` for it and a comparison
#' such as `x < 1` is not, and a file whose minimum may be -2^31 is never
#' pruned on its null count. Columns zulake does not return are not lost silently: nested
#' columns (`struct`, `array`, `map`), and decimals of precision above 15
#' until qio reads them exactly. With `columns = NULL` they are left out, each named in a
#' warning of class `zulake_warning_column_skipped` (fields `column` and
#' `reason`); named in `columns` or used in `filter`, such a column is an
#' error of class `zulake_error_column_unreadable` with the same fields.
#'
#' Data files are read in place on local disk. On Azure, every file left
#' after pruning is downloaded to the session's temporary directory
#' ([tempdir()]) before the first piece is read, by `lake_walk()` too, and
#' kept there for the rest of the session, so that a later read of the same
#' file downloads nothing. The disk used is the size of the files left after
#' pruning: `lake_walk()` reads tables larger than memory, not larger than
#' the temporary directory's disk.
#'
#' Rows a deletion vector marks as deleted are never returned (see
#' [lake_deletion_vectors()]); reading their vectors needs the zuroar
#' package, and without it a read of a table with deletion vectors in the
#' files it reads is an error of class `zulake_error_missing_package`. Every
#' such vector is read and checked before any data file, so a corrupt one
#' (`zulake_error_corrupt_log`) returns no rows. A table that maps column
#' names (column mapping in `name` mode) is read by each column's physical
#' name in the files and returned with its logical names; a
#' `timestamp_ntz` column is a `POSIXct` in UTC.
#'
#' @inheritParams lake_files
#' @param columns Columns to return, a character vector of column names, in
#'   that order. `NULL`, the default, returns every column qio can return.
#' @param filter An expression over column names; see Details. `NULL`, the
#'   default, keeps every row.
#' @param int64 How 64-bit integers reach R, in data and partition columns:
#'   `"double"` (the default), exact up to 2^53 - 1 (qio returns `NA` with a
#'   warning past it, and a `long` partition value past 2^53 - 1 is an error
#'   of class `zulake_error_int64`), or `"integer64"` from the bit64
#'   package.
#' @param FUN A function, called with each piece: a data frame of one file's
#'   matching rows, in the same columns as `lake_read()` returns. Files
#'   without a matching row are skipped.
#' @returns `lake_read()` returns a data frame with one column per column
#'   asked for and one row per matching row, in the order of the files in
#'   [lake_files()] and of the rows in each file. `lake_walk()` returns
#'   `NULL`, invisibly.
#' @seealso [lake_files()] to see which files a filter keeps, [lake_count()]
#'   for the number of rows from the log alone.
#' @export
#' @examples
#' # The example table the package ships: orders partitioned by region, five versions.
#' path <- system.file("extdata", "orders", package = "zulake")
#' tbl <- lake_open(path)
#' head(lake_read(tbl))
#' lake_read(tbl, columns = c("order_id", "amount"), filter = region == "EU" & amount > 100)
#' # Row-wise functions filter rows; dates compare as dates.
#' lake_read(tbl, filter = order_date >= as.Date("2025-01-08") & nchar(customer) == 3)
#'
#' # One file at a time, for a table larger than memory:
#' total <- 0
#' lake_walk(tbl, function(piece) total <<- total + sum(piece$amount))
#' total
lake_read <- function(tbl, columns = NULL, filter = NULL, int64 = c("double", "integer64")) {
  check_table(tbl)
  int64 <- check_int64(int64)
  scan <- read_scan(tbl, columns, substitute(filter), parent.frame(), int64)
  pieces <- lapply(seq_along(scan$keep), function(k) read_piece(scan, k))
  bind_pieces(pieces, scan)
}

#' @rdname lake_read
#' @export
lake_walk <- function(tbl, FUN, columns = NULL, filter = NULL, int64 = c("double", "integer64")) {
  check_table(tbl)
  if (!is.function(FUN)) {
    zulake_abort("argument", "`FUN` must be a function.")
  }
  int64 <- check_int64(int64)
  scan <- read_scan(tbl, columns, substitute(filter), parent.frame(), int64)
  for (k in seq_along(scan$keep)) {
    piece <- read_piece(scan, k)
    if (nrow(piece)) {
      FUN(piece)
    }
  }
  invisible(NULL)
}

# ---- the read pipeline ------------------------------------------------------
#
# read_scan() decides everything before a row is read: refusals, the filter
# plan, the files that survive pruning (fetched to local paths: on Azure
# every one is downloaded into tempdir() here, before the first piece, and
# kept for the session, so a read uses disk equal to the pruned files' size,
# #75), each file's
# qio read plan, and the columns returned. read_piece() reads one surviving
# file into a filtered piece; bind_pieces() binds them. Deletion vectors,
# read in read_scan(), drop rows in read_piece(), between the read and the
# row filter.

read_scan <- function(tbl, columns, expr, env, int64) {
  types <- column_types(tbl)
  all <- names(types)
  if (!is.null(columns)) {
    if (!is.character(columns) || anyNA(columns)) {
      zulake_abort("argument", "`columns` must be NULL or a character vector of column names.")
    }
    unknown <- setdiff(columns, all)
    if (length(unknown)) {
      zulake_abort("argument", sprintf("`columns` names %s, which the table does not have.", format_string(unknown[1L])))
    }
    if (anyDuplicated(columns)) {
      zulake_abort("argument", sprintf("`columns` names %s twice.", format_string(columns[duplicated(columns)][1L])))
    }
  }
  plan <- if (!is.null(expr)) filter_plan(expr, types, env, strict = FALSE)
  keep <- prune_files(tbl, plan, int64)
  out_cols <- if (is.null(columns)) all else columns
  filter_cols <- plan_columns(plan)
  need <- all[all %in% c(out_cols, filter_cols)]
  pcols <- tbl$metadata[["partitionColumns"]]
  fields <- schema_fields(tbl)
  physical <- stats::setNames(vapply(fields, field_physical, "", mode = tbl$column_mapping), all)

  reasons <- list()
  for (col in need) {
    why <- type_unreadable(types[[col]])
    if (!is.na(why)) reasons[[col]] <- why
  }
  # Every file's location is checked before anything is read (#66, #76).
  where <- lapply(keep, function(i) resolve_file(tbl, i))
  # Deletion vectors are read and checked before any data file, so a bad
  # one returns no rows, from lake_walk() too.
  has_dv <- !vapply(tbl$files$action[keep], function(a) is.null(a[["deletionVector"]]), NA)
  deleted <- vector("list", length(keep))
  deleted[has_dv] <- dv_rows_of(tbl, keep[has_dv])
  paths <- vapply(seq_along(keep), function(k) fetch_file(tbl, keep[k], where[[k]]), "")
  data_cols <- setdiff(need, c(pcols, names(reasons)))
  plans <- lapply(paths, function(p) qio::read_plan(p, int64 = int64))
  for (k in seq_along(paths)) {
    for (col in setdiff(data_cols, names(reasons))) {
      why <- plan_unreadable(plans[[k]], physical[[col]])
      if (!is.na(why)) reasons[[col]] <- why
    }
  }
  refused <- intersect(names(reasons), c(columns, filter_cols))
  if (length(refused)) {
    col <- refused[1L]
    used <- if (col %in% columns) "named in `columns`" else "used in `filter`"
    zulake_abort(
      "column_unreadable",
      sprintf("Column %s, %s, cannot be read: %s.", format_string(col), used, reasons[[col]]),
      column = col, reason = reasons[[col]]
    )
  }
  for (col in names(reasons)) {
    zulake_warn(
      "column_skipped",
      sprintf("Column %s is left out of the read: %s.", format_string(col), reasons[[col]]),
      column = col, reason = reasons[[col]]
    )
  }
  read_cols <- setdiff(need, names(reasons))
  data_cols <- setdiff(read_cols, pcols)
  present <- lapply(plans, function(pl) {
    flat <- pl$path[!pl$nested]
    data_cols[physical[data_cols] %in% flat]
  })
  vetted <- vapply(seq_along(plans), function(k) {
    pl <- plans[[k]]
    dec <- pl$path[!pl$nested & pl$logical_type %in% "DECIMAL"]
    dec <- intersect(dec, physical[present[[k]]])
    cols <- names(physical)[match(dec, physical)]
    all(vapply(types[cols], function(t) {
      ps <- decimal_ps(t)
      !is.null(ps) && ps[["precision"]] <= max_double_precision
    }, NA))
  }, NA)
  list(
    tbl = tbl, keep = keep, paths = paths, plan = plan, env = env, int64 = int64,
    types = types, physical = physical, read_cols = read_cols, out_cols = setdiff(out_cols, names(reasons)),
    present = present, vetted = vetted, deleted = deleted,
    parts = partition_read_table(tbl$files$action[keep], tbl, int64, intersect(read_cols, pcols))
  )
}

# Why qio cannot return a column of Delta type `type`, or NA.
type_unreadable <- function(type) {
  if (type %in% c("struct", "array", "map")) {
    return(sprintf("it is a nested column (%s), which zulake does not read yet (design D14)", type))
  }
  ps <- decimal_ps(type)
  if (!is.null(ps) && ps[["precision"]] > max_double_precision) {
    return(sprintf(
      "decimal precision %s > %d, which a double cannot hold exactly; qio reads exact decimals from version 0.2.0",
      format_number(ps[["precision"]]), max_double_precision
    ))
  }
  NA_character_
}

# Why a file's qio read plan cannot return column `name` (its name in the
# file), or NA; a column the file does not have is read as NA, not refused.
plan_unreadable <- function(plan, name) {
  flat <- !plan$nested & plan$path == name
  if (any(flat)) {
    if (all(plan$collectible[flat])) {
      return(NA_character_)
    }
    note <- plan$note[flat & !plan$collectible][1L]
    return(sprintf("qio cannot read it (%s)", if (is.na(note)) "no reason given" else note))
  }
  if (any(plan$nested & startsWith(plan$path, paste0(name, ".")))) {
    return("it is a nested column, which zulake does not read yet (design D14)")
  }
  NA_character_
}

# One surviving file's rows: read with qio, partition columns added, absent
# columns filled with NA, the rows its deletion vector marks dropped, then
# the filter applied to rows.
read_piece <- function(scan, k) {
  i <- scan$keep[k]
  sel <- scan$present[[k]]
  read <- function() {
    qio::read_parquet(scan$paths[k], columns = unname(scan$physical[sel]), int64 = scan$int64)
  }
  df <- withCallingHandlers(read(), message = qio_decimal_muffler(scan$vetted[k]))
  n <- nrow(df)
  gone <- scan$deleted[[k]]
  if (length(gone) && gone[length(gone)] >= n) {
    file <- scan$tbl$files$path[i]
    zulake_abort(
      "corrupt_log",
      sprintf(
        "The deletion vector of file %s deletes row %s, but the file has %s rows.",
        format_string(file), format_number(gone[length(gone)]), format_number(n)
      ),
      file = file
    )
  }
  cols <- list()
  for (col in scan$read_cols) {
    cols[[col]] <- if (col %in% names(scan$parts)) {
      scan$parts[[col]][rep(k, n)]
    } else if (col %in% sel) {
      df[[scan$physical[[col]]]]
    } else {
      empty_column(scan$types[[col]], scan$int64, n)
    }
  }
  if (length(gone)) {
    alive <- seq_len(n)[-(gone + 1)]
    cols <- lapply(cols, function(x) x[alive])
    n <- length(alive)
  }
  piece <- new_data_frame_n(cols, n)
  if (!is.null(scan$plan)) {
    rows <- which(filter_rows(scan$plan, piece, scan$env) %in% TRUE)
    piece <- new_data_frame_n(lapply(cols, function(x) x[rows]), length(rows))
  }
  piece[scan$out_cols]
}

# NA values of the R type qio returns for Delta type `type` (design section 7).
empty_column <- function(type, int64, n) {
  if (grepl("^decimal", type)) {
    return(rep(NA_real_, n))
  }
  switch(type,
    byte = ,
    short = ,
    integer = rep(NA_integer_, n),
    long = if (int64 == "integer64") bit64::as.integer64(rep(NA, n)) else rep(NA_real_, n),
    float = ,
    double = rep(NA_real_, n),
    string = rep(NA_character_, n),
    binary = vector("list", n),
    boolean = rep(NA, n),
    date = structure(rep(NA_real_, n), class = "Date"),
    timestamp = ,
    timestamp_ntz = structure(rep(NA_real_, n), class = c("POSIXct", "POSIXt"), tzone = "UTC"),
    rep(NA, n)
  )
}

# The pieces as one data frame; with no pieces, no rows of the right types.
bind_pieces <- function(pieces, scan) {
  if (!length(pieces)) {
    cols <- list()
    for (col in scan$out_cols) {
      cols[[col]] <- if (col %in% names(scan$parts)) scan$parts[[col]][0L] else empty_column(scan$types[[col]], scan$int64, 0L)
    }
    return(new_data_frame_n(cols, 0L))
  }
  n <- sum(vapply(pieces, nrow, 0L))
  cols <- list()
  for (col in scan$out_cols) {
    parts <- lapply(pieces, `[[`, col)
    first <- parts[[1L]]
    for (j in seq_along(parts)) {
      if (!identical(class(parts[[j]]), class(first))) {
        zulake_abort(
          "corrupt_log",
          sprintf(
            "column %s reads as %s from one file and %s from another; the files of a table must agree on its type.",
            format_string(col), class(first)[1L], class(parts[[j]])[1L]
          ),
          column = col
        )
      }
    }
    cols[[col]] <- if (is.list(first)) {
      do.call(c, parts)
    } else {
      out <- unlist(lapply(parts, unclass), use.names = FALSE)
      keep <- attributes(first)
      keep$names <- NULL
      attributes(out) <- keep
      out
    }
  }
  new_data_frame_n(cols, n)
}

# ---- files on disk ----------------------------------------------------------

cache_env <- new.env(parent = emptyenv())

# The credentials function a backend's requests use (NULL for anonymous
# ones and for other backends). A cached file is served only to the same
# function that downloaded it, so a snapshot opened with other credentials
# (another principal, a path-scoped token) downloads it itself, and is
# refused if Azure refuses it (#72). A snapshot restored in another session
# gets zulake_error_auth here, as on its next request.
cache_credentials <- function(storage) {
  handle <- storage$location$handle
  if (identical(storage$kind, "azure") && !is.null(handle)) credential_entry(handle)$fn
}

# Where live file `i` is, before anything is read: list(local) for an
# absolute local path, or list(storage, rel, key) for a file of a backend,
# read in place when the backend has local paths and downloaded otherwise. Refusals come here, so
# read_scan() and lake_count() make them for every file before reading any:
# a relative path with an empty, "." or ".." segment (#66) and an absolute
# path off the table's storage (#44, #76).
resolve_file <- function(tbl, i) {
  path <- tbl$files$action[[i]][["path"]]
  storage <- tbl$storage
  if (is_absolute_path(path)) {
    remote <- storage_for_absolute(storage, path)
    if (is.null(remote)) {
      return(list(local = absolute_local_path(path), path = path))
    }
    storage <- remote$storage
    rel <- remote$rel
  } else {
    rel <- percent_decode(path)
    if (bad_relative_path(rel)) {
      zulake_abort(
        "corrupt_log",
        sprintf("file %s has an empty, \".\" or \"..\" path segment, which would leave the table's root.", format_string(path)),
        file = path
      )
    }
  }
  list(storage = storage, rel = rel, path = path, key = cache_key(storage, rel))
}

# Whether a relative path (decoded) has an empty, "." or ".." segment.
bad_relative_path <- function(rel) {
  !nzchar(rel) || any(strsplit(rel, "/", fixed = TRUE)[[1L]] %in% c("", ".", "..")) || endsWith(rel, "/")
}

# What identifies a downloaded file in the session cache: on Azure the blob
# itself (account, container, full decoded name), so that the three URI
# forms of one table, a host in upper case and an encoded root share it
# (#72); for another backend, its root and the path. The credentials that
# fetched it are checked apart (cache_credentials()).
cache_key <- function(storage, rel) {
  loc <- storage$location
  parts <- if (identical(storage$kind, "azure")) {
    blob <- if (nzchar(loc$path)) paste0(loc$path, "/", rel) else rel
    c("azure", loc$account, loc$container, blob)
  } else {
    c(storage$kind %||% "", storage$root, rel)
  }
  paste(parts, collapse = "\x1f")
}

cache_env <- new.env(parent = emptyenv())

# The local path of live file `i`, from resolve_file(): the file itself on
# local disk, otherwise a copy downloaded through the storage backend once
# per session (design section 4.3) into tempdir(), keyed by cache_key(), the
# size and the modification time, which never change for a Delta data file.
# A copy is written under a temporary name and renamed when whole, and one
# whose size on disk is not the log's is downloaded again.
fetch_file <- function(tbl, i, where = resolve_file(tbl, i)) {
  path <- where$path
  if (!is.null(where$local)) {
    local <- where$local
    if (!file.exists(local) || dir.exists(local)) {
      zulake_abort("storage", sprintf("cannot read %s: no such file.", format_string(path)), path = path)
    }
    return(local)
  }
  if (is.function(where$storage$local_path)) {
    return(where$storage$local_path(where$rel))
  }
  a <- tbl$files$action[[i]]
  size <- a[["size"]]
  key <- paste(where$key, int_text(size %||% -1), int_text(a[["modificationTime"]] %||% -1), sep = "\x1f")
  fn <- cache_credentials(where$storage)
  hit <- cache_env$files[[key]]
  if (!is.null(hit) && identical(hit$fn, fn) && file.exists(hit$file) &&
      (!is_whole(size) || identical(file.size(hit$file), as.numeric(size)))) {
    return(hit$file)
  }
  bytes <- where$storage$get(where$rel)
  if (is_whole(size) && length(bytes) != size) {
    zulake_abort(
      "storage",
      sprintf(
        "data file %s has %s bytes, but the log says %s.",
        format_string(path), format_number(length(bytes)), format_number(size)
      ),
      path = path
    )
  }
  dir <- file.path(tempdir(), "zulake-cache")
  dir.create(dir, showWarnings = FALSE)
  f <- tempfile("data-", tmpdir = dir, fileext = ".parquet")
  part <- paste0(f, ".part")
  ok <- FALSE
  on.exit(if (!ok) unlink(part), add = TRUE)
  writeBin(bytes, part)
  if (!file.rename(part, f)) {
    zulake_abort("storage", sprintf("cannot write a copy of %s to %s.", format_string(path), format_string(dir)), path = path)
  }
  ok <- TRUE
  if (is.null(cache_env$files)) {
    cache_env$files <- list()
  }
  cache_env$files[[key]] <- list(file = f, fn = fn)
  f
}

# Whether a path from the log (an `add` path, a deletion vector's absolute
# path) is absolute: a URI with a scheme, or a path from the root.
is_absolute_path <- function(path) {
  startsWith(path, "/") || grepl("^[A-Za-z]:[/\\\\]", path) || grepl("^[A-Za-z][A-Za-z0-9+.-]*:", path)
}

# The local path of an absolute path from the log: itself, or the path of a
# file: URI; other schemes are a zulake_error_uri.
absolute_local_path <- function(path) {
  if (startsWith(path, "/") || grepl("^[A-Za-z]:[/\\\\]", path)) {
    return(path)
  }
  if (startsWith(path, "file:")) {
    # file:///home/x, file:/home/x, and file:///C:/x on Windows.
    return(sub("^/([A-Za-z]:)", "\\1", percent_decode(sub("^file:(//)?", "", path))))
  }
  zulake_abort(
    "uri",
    sprintf("%s is at a location zulake cannot read yet.", format_string(path)),
    path = path
  )
}

# The number of rows of live file `i`, from its Parquet footer.
footer_rows <- function(tbl, i, where = resolve_file(tbl, i)) {
  pf <- qio::open_parquet(fetch_file(tbl, i, where))
  on.exit(qio::close_parquet(pf))
  as.numeric(dim(pf)[1L])
}

# A message handler for the one message qio emits per read when it returns
# decimal columns as doubles, saying the values may be inexact. A decimal of
# precision 15 or less is exact as a double (design section 7), so the
# message is muffled when every decimal column read is that narrow:
#
# - qio from pedrobtz/qio#75 on signals class `qio_message_decimal_double`
#   with a `columns` data frame giving each column's `precision`, so the
#   check is made on the columns the message names;
# - older qio (0.1.1, 0.1.2 on CRAN) sends unclassed text, so the check is
#   `vetted`, made by zulake from the read plan before the read.
#
# Every other message passes through.
qio_decimal_muffler <- function(vetted) {
  function(m) {
    if (inherits(m, "qio_message_decimal_double")) {
      precision <- m$columns$precision
      if (length(precision) && all(!is.na(precision) & precision <= max_double_precision)) {
        invokeRestart("muffleMessage")
      }
    } else if (isTRUE(vetted) && inherits(m, "simpleMessage") &&
               grepl("Parquet DECIMAL columns? as double", conditionMessage(m))) {
      invokeRestart("muffleMessage")
    }
  }
}

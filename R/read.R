#' Read a table's rows
#'
#' `lake_read()` returns the rows of a snapshot as a data frame. It prunes
#' the live files with `filter` first, so that only the files whose rows
#' could match are read, then reads each one with qio, adds the partition
#' columns from the log, keeps the rows `filter` is `TRUE` for, and binds the
#' pieces. `lake_walk()` does the same one file at a time and calls `FUN` on
#' each piece instead of binding them, for tables larger than memory.
#'
#' `filter` is an unevaluated R expression over column names, with values
#' from the calling environment (a column's name always means the column).
#' Its pruning subset is comparisons (`==`, `!=`, `<`, `<=`, `>`, `>=`),
#' `%in%` and `is.na()` between a column and values, joined by `!`, `&` and
#' `|`. That subset rules files out by their partition values and their
#' statistics (minimum, maximum, null count and record count); anything else
#' in the expression is only applied to rows. Statistics only decide what is
#' read: the rows returned are the rows `filter` is `TRUE` for whatever the
#' statistics say, and a missing statistic only means a file is read.
#'
#' Inside the pruning subset, comparisons are exact: a `long`, `integer`,
#' `short`, `byte` or `decimal` column is compared with the value as decimal
#' numbers, digit by digit, and a `string` column in UTF-8 byte order
#' whatever the session's collation, as the table's statistics are. A value
#' given as text, such as `"12.30"`, is read as that decimal number; a double
#' that has no exact decimal form of 15 digits (`1/3`, `0.1 + 0.2`) is an
#' error asking for the value as text. A date or timestamp column takes a
#' `Date` or `POSIXct`, or text such as `"2024-01-31"` or
#' `"2024-01-31 12:00:00"` (UTC unless it gives an offset).
#'
#' Columns are typed as qio returns them (see [qio::read_parquet()]), and
#' partition columns as [lake_files()] types them, except that a `decimal`
#' of precision 15 or less, data or partition, is a double, which holds it
#' exactly. Columns qio cannot return are not lost silently: nested columns
#' (`struct`, `array`, `map`) and decimals of precision above 15, until qio
#' reads them. With `columns = NULL` they are left out, each named in a
#' warning of class `zulake_warning_column_skipped` (fields `column` and
#' `reason`); named in `columns` or used in `filter`, such a column is an
#' error of class `zulake_error_column_unreadable` with the same fields.
#'
#' Data files are read in place on local disk; other stores download each
#' file once per session, to the session's temporary directory.
#'
#' This version cannot read a table whose live files have deletion vectors,
#' or that maps column names: both are refused with a
#' `zulake_error_unsupported_feature` error naming the feature, before any
#' data file is read, so a read never returns deleted rows or wrong columns.
#'
#' @inheritParams lake_files
#' @param columns Columns to return, a character vector of column names, in
#'   that order. `NULL`, the default, returns every column qio can return.
#' @param filter An expression over column names; see Details. `NULL`, the
#'   default, keeps every row.
#' @param int64 How 64-bit integers reach R, in data and partition columns:
#'   `"double"` (the default), exact up to 2^53 (qio returns `NA` with a
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
#' # A partitioned table of two files: the data written with qio, the log by
#' # hand.
#' path <- tempfile("table")
#' dir.create(file.path(path, "_delta_log"), recursive = TRUE)
#' add <- function(year, ids) {
#'   file <- sprintf("year=%d/part-0.parquet", year)
#'   dir.create(file.path(path, dirname(file)))
#'   qio::write_parquet(data.frame(id = ids), file.path(path, file))
#'   sprintf(
#'     paste0(
#'       '{"add":{"path":"%s","partitionValues":{"year":"%d"},"size":%.0f,',
#'       '"modificationTime":0,"dataChange":true,"stats":"{\\"numRecords\\":%d,',
#'       '\\"minValues\\":{\\"id\\":%g},\\"maxValues\\":{\\"id\\":%g},',
#'       '\\"nullCount\\":{\\"id\\":0}}"}}'
#'     ),
#'     file, year, file.size(file.path(path, file)), length(ids), min(ids), max(ids)
#'   )
#' }
#' writeLines(c(
#'   '{"protocol":{"minReaderVersion":1,"minWriterVersion":2}}',
#'   paste0(
#'     '{"metaData":{"id":"example","format":{"provider":"parquet","options":{}},',
#'     '"schemaString":"{\\"type\\":\\"struct\\",\\"fields\\":[',
#'     '{\\"name\\":\\"id\\",\\"type\\":\\"double\\",\\"nullable\\":true,\\"metadata\\":{}},',
#'     '{\\"name\\":\\"year\\",\\"type\\":\\"integer\\",\\"nullable\\":true,\\"metadata\\":{}}]}",',
#'     '"partitionColumns":["year"],"configuration":{}}}'
#'   ),
#'   add(2025, c(1, 2, 3)),
#'   add(2026, c(4, 5))
#' ), file.path(path, "_delta_log", "00000000000000000000.json"))
#'
#' tbl <- lake_open(path)
#' lake_read(tbl)
#' lake_read(tbl, filter = id >= 3 & year == 2026)
#' # The statistics alone rule out the 2025 file for this filter:
#' lake_files(tbl, filter = id > 3)$path
#' lake_walk(tbl, function(piece) print(nrow(piece)))
#'
#' unlink(path, recursive = TRUE)
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
# plan, the files that survive pruning (fetched to local paths), each file's
# qio read plan, and the columns returned. read_piece() reads one surviving
# file into a filtered piece; bind_pieces() binds them. Stage 5's deletion
# vectors drop rows in read_piece(), between the read and the row filter.

read_scan <- function(tbl, columns, expr, env, int64) {
  read_refusals(tbl)
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
  paths <- vapply(keep, function(i) fetch_file(tbl, i), "")
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
    present = present, vetted = vetted,
    parts = partition_read_table(tbl$files$action[keep], tbl, int64, intersect(read_cols, pcols))
  )
}

# Why qio cannot return a column of Delta type `type`, or NA.
type_unreadable <- function(type) {
  if (type %in% c("struct", "array", "map")) {
    return(sprintf("it is a nested column (%s), which qio reads from version 0.2.0", type))
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
    return("it is a nested column, which qio reads from version 0.2.0")
  }
  NA_character_
}

# Refuses a snapshot whose rows this version cannot read correctly.
read_refusals <- function(tbl) {
  dv <- !vapply(tbl$files$action, function(a) is.null(a[["deletionVector"]]), NA)
  if (any(dv)) {
    read_refuse(
      tbl, "deletionVectors",
      sprintf(
        "%s of its live files %s deletion vectors, which zulake cannot apply to rows yet (reads of such tables arrive with Stage 5); lake_files() and lake_count() still work",
        format_number(sum(dv)), if (sum(dv) == 1) "has" else "have"
      )
    )
  }
  if (tbl$column_mapping != "none") {
    read_refuse(
      tbl, "columnMapping",
      "it maps column names (column mapping), which zulake cannot apply to rows yet (reads of such tables arrive with Stage 5); lake_files() and lake_count() still work"
    )
  }
  invisible()
}

read_refuse <- function(tbl, feature, why) {
  zulake_abort(
    "unsupported_feature",
    sprintf("Version %s of this table cannot be read: %s.", format_number(tbl$version), why),
    feature = feature,
    version = tbl$version,
    protocol = protocol_frame(tbl$protocol, tbl$metadata)
  )
}

# One surviving file's rows: read with qio, partition columns added, absent
# columns filled with NA, then the filter applied to rows.
read_piece <- function(scan, k) {
  i <- scan$keep[k]
  sel <- scan$present[[k]]
  read <- function() {
    qio::read_parquet(scan$paths[k], columns = unname(scan$physical[sel]), int64 = scan$int64)
  }
  df <- if (scan$vetted[k]) {
    # qio says once per read that decimals are doubles and may be inexact;
    # each one here is of precision 15 or less, which a double holds
    # exactly. pedrobtz/qio#74 would give that message a class.
    withCallingHandlers(read(), message = function(m) {
      if (grepl("Parquet DECIMAL columns? as double", conditionMessage(m))) {
        invokeRestart("muffleMessage")
      }
    })
  } else {
    read()
  }
  n <- nrow(df)
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

# The local path of live file `i`: the file itself on local disk, otherwise a
# copy downloaded through the storage backend once per session (design
# section 4.3), keyed by the table, path, size and modification time, which
# never change for a Delta data file.
fetch_file <- function(tbl, i) {
  a <- tbl$files$action[[i]]
  path <- a[["path"]]
  storage <- tbl$storage
  if (grepl("^[A-Za-z][A-Za-z0-9+.-]*:", path) && !grepl("^[A-Za-z]:[/\\\\]", path) || startsWith(path, "/")) {
    local <- if (startsWith(path, "/") || grepl("^[A-Za-z]:[/\\\\]", path)) {
      path
    } else if (startsWith(path, "file:")) {
      # file:///home/x, file:/home/x, and file:///C:/x on Windows.
      sub("^/([A-Za-z]:)", "\\1", percent_decode(sub("^file:(//)?", "", path)))
    } else {
      zulake_abort(
        "uri",
        sprintf("data file %s is at a location zulake cannot read yet.", format_string(path)),
        path = path
      )
    }
    if (!file.exists(local) || dir.exists(local)) {
      zulake_abort("storage", sprintf("cannot read %s: no such file.", format_string(path)), path = path)
    }
    return(local)
  }
  rel <- percent_decode(path)
  if (is.function(storage$local_path)) {
    return(storage$local_path(rel))
  }
  size <- a[["size"]]
  key <- paste(storage$root, rel, int_text(size %||% -1), int_text(a[["modificationTime"]] %||% -1), sep = "\x1f")
  hit <- cache_env$files[[key]]
  if (!is.null(hit) && file.exists(hit)) {
    return(hit)
  }
  bytes <- storage$get(rel)
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
  writeBin(bytes, f)
  if (is.null(cache_env$files)) {
    cache_env$files <- list()
  }
  cache_env$files[[key]] <- f
  f
}

# The number of rows of live file `i`, from its Parquet footer.
footer_rows <- function(tbl, i) {
  pf <- qio::open_parquet(fetch_file(tbl, i))
  on.exit(qio::close_parquet(pf))
  as.numeric(dim(pf)[1L])
}

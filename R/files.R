#' The files of a snapshot
#'
#' `lake_files()` lists the snapshot's live files, one row per `add` action
#' in force, with their partition values, statistics and deletion vector
#' descriptors. `lake_partitions()` gives the distinct partition values of
#' those files. `lake_removed()` lists the tombstones (`remove` actions)
#' still in the log. `lake_count()` counts the snapshot's rows from the log
#' alone.
#'
#' Partition values are typed by the column's Delta type: `byte` and
#' `short` as integers, `integer` as doubles (an R integer cannot hold
#' -2^31), `long` as 64-bit values (see `int64`), `float` and `double` as
#' doubles (a `float` rounded through single precision, as its data
#' column reads), `boolean` as logicals, `date` as `Date`,
#' `timestamp` and `timestamp_ntz` as `POSIXct` in UTC, and `decimal`,
#' `string` and `binary` as the text the log holds. A null partition value
#' is `NA`.
#'
#' Statistics come from each file's `stats` JSON, keyed by column name:
#' `min` and `max` typed as partition values are, except that a `decimal`
#' statistic stays its JSON text exactly as the log writes it, since a
#' double would round it; `null_count` and `num_records` are 64-bit counts.
#' A `long` minimum or maximum that `int64` cannot hold (past 2^53 - 1 as a
#' double, or -2^63, which bit64 keeps for `NA`) is `NA`, with a warning of
#' class `zulake_warning_int64` (fields `value`, `column` and `path`) once
#' per column; its digits stay in `action`. Statistics are optional in the
#' protocol, so a file can have none (`NA` and `NULL`).
#'
#' `filter` is an unevaluated R expression over column names, of
#' comparisons (`==`, `!=`, `<`, `<=`, `>`, `>=`), `%in%` and `is.na()`
#' joined by `!`, `&` and `|`, with literals or values from the calling
#' environment. A file is kept when the filter can be `TRUE` for one of its
#' rows: a comparison on a partition column is decided by the file's
#' partition value, one on another column by the file's statistics, and a
#' file without statistics for that column is kept. Values compare exactly,
#' as [lake_read()] describes. Anything else, the row-wise functions
#' [lake_read()] applies to rows included, is refused with a
#' `zulake_error_filter` error, since there are no rows here to apply it
#' to.
#'
#' @param tbl A snapshot, from [lake_open()] or [lake_load()].
#' @param filter An expression over column names; see Details. `NULL`, the
#'   default, keeps every file.
#' @param stats Whether to parse the files' statistics into `num_records`,
#'   `null_count`, `min` and `max`.
#' @param int64 How 64-bit integers from the log are returned: `"double"`
#'   (the default), exact up to 2^53 - 1 and an error of class
#'   `zulake_error_int64` beyond it, or `"integer64"`, from the bit64
#'   package, exact from -2^63 + 1 to 2^63 - 1 (bit64 keeps -2^63 for `NA`,
#'   so that value is an error too). It applies to the columns that hold
#'   64-bit counts and values; inside an action or `commitInfo` as the log
#'   writes it, only a number a double cannot hold becomes an integer64.
#' @returns `lake_files()` returns a data frame with one row per live file,
#'   sorted by path: `path` (as the log writes it, relative to the table or
#'   absolute), `uri` (where the file is), `size_bytes`,
#'   `modification_time` (`POSIXct`), `data_change`, `partition` (a list
#'   column of named lists of typed values), `deletion_vector` (a list
#'   column: the descriptor, or `NULL`), then, with `stats = TRUE`,
#'   `num_records`, `null_count`, `min` and `max`, and last `action`, the
#'   `add` action as the log holds it.
#'
#'   `lake_partitions()` returns a data frame with one column per partition
#'   column and one row per distinct combination of values among the live
#'   files the filter keeps, distinct as the log writes them (so `"1"` and
#'   `"1.0"` are two rows, as in `deltalake`); a table without partition
#'   columns has none.
#'
#'   `lake_removed()` returns a data frame with one row per tombstone:
#'   `path`, `deletion_timestamp` (`POSIXct`), `data_change`, `size_bytes`,
#'   `partition_values` (a list column of the values as the log writes
#'   them), `deletion_vector` and `action`.
#'
#'   `lake_count()` returns the number of rows, a double: the sum of
#'   `numRecords` over the live files minus the rows their deletion vectors
#'   delete (each descriptor's `cardinality`). When a live file has no
#'   `numRecords` the count is unknown: `NA_real_`, with a warning of class
#'   `zulake_warning_count_unknown` whose `files` field gives the number of
#'   such files, unless `footers = TRUE` reads those files' row counts from
#'   their Parquet footers. It is never a partial sum. A file with a
#'   deletion vector and no `numRecords` breaks the protocol:
#'   `zulake_error_corrupt_log`.
#' @seealso [lake_summary()] for the totals in one row, [lake_changes()] for
#'   the files added and removed between two versions.
#' @export
#' @examples
#' # The example table the package ships: orders partitioned by region, five versions.
#' path <- system.file("extdata", "orders", package = "zulake")
#' tbl <- lake_open(path)
#' lake_files(tbl)[c("path", "size_bytes", "num_records")]
#' # Partition values and statistics decide which files a filter can match:
#' lake_files(tbl, filter = region == "EU" & amount > 1000)$path
#' lake_partitions(tbl)
#' lake_removed(tbl)[c("path", "deletion_timestamp")]
#' lake_count(tbl)
lake_files <- function(
  tbl,
  filter = NULL,
  stats = TRUE,
  int64 = c("double", "integer64")
) {
  check_table(tbl)
  int64 <- check_int64(int64)
  if (!isTRUE(stats) && !isFALSE(stats)) {
    zulake_abort("argument", "`stats` must be TRUE or FALSE.")
  }
  keep <- filter_files(tbl, substitute(filter), parent.frame(), int64)
  add_frame(tbl, tbl$files$action[keep], stats, int64)
}

#' @rdname lake_files
#' @export
lake_partitions <- function(
  tbl,
  filter = NULL,
  int64 = c("double", "integer64")
) {
  check_table(tbl)
  int64 <- check_int64(int64)
  keep <- filter_files(tbl, substitute(filter), parent.frame(), int64)
  parts <- partition_table(tbl$files$action[keep], tbl, int64)
  if (!length(parts)) {
    return(new_data_frame(list(), 0L))
  }
  # Distinct on the log's own text, as deltalake 1.7.0 is: typed values
  # print to 15 digits, lose the sign of zero, and NaN is.na() (#55).
  actions <- tbl$files$action[keep]
  key <- do.call(
    paste,
    c(
      lapply(names(parts), function(col) {
        raw <- partition_raw(actions, tbl, col)
        ifelse(is.na(raw), "N", paste0("V", raw))
      }),
      sep = "\x1e"
    )
  )
  parts <- parts[!duplicated(key), , drop = FALSE]
  ord <- do.call(
    order,
    c(
      unname(lapply(parts, function(col) {
        if (inherits(col, "integer64")) integer64_order_key(col) else col
      })),
      method = "radix",
      na.last = TRUE
    )
  )
  parts <- parts[ord, , drop = FALSE]
  row.names(parts) <- NULL
  parts
}

# Text that sorts as the integer64 values `x` do, NA as NA: the sign, then
# the digits padded to 20 places, complemented for a negative value.
integer64_order_key <- function(x) {
  text <- as.character(x)
  neg <- !is.na(text) & startsWith(text, "-")
  digits <- sub("^-", "", text)
  padded <- paste0(strrep("0", pmax(0L, 20L - nchar(digits))), digits)
  out <- ifelse(
    neg,
    paste0("0", chartr("0123456789", "9876543210", padded)),
    paste0("1", padded)
  )
  out[is.na(text)] <- NA_character_
  out
}

#' @rdname lake_files
#' @export
lake_removed <- function(tbl, int64 = c("double", "integer64")) {
  check_table(tbl)
  int64 <- check_int64(int64)
  a <- tbl$removed$action
  ts <- int64_values(
    lapply(a, function(x) x[["deletionTimestamp"]]),
    "double",
    "a remove's `deletionTimestamp`"
  )
  new_data_frame(list(
    path = tbl$removed$path,
    deletion_timestamp = ms_to_posixct(ts),
    data_change = logical_field(a, "dataChange"),
    size_bytes = int64_values(
      lapply(a, function(x) x[["size"]]),
      int64,
      "a remove's `size`"
    ),
    partition_values = lapply(a, function(x) {
      string_map(x[["partitionValues"]])
    }),
    deletion_vector = lapply(a, function(x) {
      dv_descriptor(x[["deletionVector"]], int64)
    }),
    action = lapply(a, unmark_tree, int64 = int64, what = "a `remove` action")
  ))
}

#' @rdname lake_files
#' @param footers Whether to read the row count of each live file that has
#'   no `numRecords` statistic from its Parquet footer, which downloads
#'   those files. `FALSE`, the default, reads nothing but the log.
#' @export
lake_count <- function(tbl, footers = FALSE) {
  check_table(tbl)
  if (!isTRUE(footers) && !isFALSE(footers)) {
    zulake_abort("argument", "`footers` must be TRUE or FALSE.")
  }
  counts <- file_counts(tbl, "double")
  if (!counts$without_records) {
    return(counts$records)
  }
  if (footers) {
    where <- lapply(counts$missing, function(i) resolve_file(tbl, i))
    rows <- vapply(
      seq_along(where),
      function(k) footer_rows(tbl, counts$missing[k], where[[k]]),
      0
    )
    known <- int64_sum(
      counts$per_file[-counts$missing],
      "double",
      "The number of records"
    )
    return(
      int64_sum(c(known, rows), "double", "The number of records") -
        counts$deleted
    )
  }
  n <- counts$without_records
  zulake_warn(
    "count_unknown",
    sprintf(
      paste(
        "%s live file%s no `numRecords` statistic, so the row count is unknown",
        "(NA); `lake_files()` shows which, and `footers = TRUE` reads their",
        "counts from the files."
      ),
      format_number(n),
      if (n == 1) " has" else "s have"
    ),
    files = n
  )
  NA_real_
}

# ---- building the frames -------------------------------------------------

# The data frame lake_files() returns, for `actions` (add actions).
add_frame <- function(tbl, actions, stats, int64) {
  paths <- vapply(actions, function(a) a[["path"]], "", USE.NAMES = FALSE)
  parts <- partition_table(actions, tbl, int64)
  out <- list(
    path = paths,
    uri = file_uri(tbl, paths),
    size_bytes = int64_values(
      lapply(actions, function(a) a[["size"]]),
      int64,
      "an add's `size`"
    ),
    modification_time = ms_to_posixct(
      int64_values(
        lapply(actions, function(a) a[["modificationTime"]]),
        "double",
        "an add's `modificationTime`"
      )
    ),
    data_change = logical_field(actions, "dataChange"),
    partition = lapply(seq_along(actions), function(i) frame_row(parts, i)),
    deletion_vector = lapply(actions, function(a) {
      dv_descriptor(a[["deletionVector"]], int64)
    })
  )
  if (stats) {
    out <- c(out, stats_columns(tbl, actions, paths, int64))
  }
  out$action <- lapply(
    actions,
    unmark_tree,
    int64 = int64,
    what = "an `add` action"
  )
  new_data_frame(out, length(actions))
}

stats_columns <- function(tbl, actions, paths, int64) {
  parsed <- parse_stats(file_stats_text(actions), paths)
  fields <- schema_fields(tbl)
  mode <- tbl$column_mapping
  skipped <- new.env(parent = emptyenv())
  skipped$values <- list()
  skipped$paths <- list()
  obj <- function(name, kind) {
    lapply(seq_along(parsed), function(i) {
      what <- sprintf(
        "the %s statistics of file %s",
        name,
        format_string(paths[i])
      )
      skipped$path <- paths[i]
      stats_object(
        parsed[[i]][[name]],
        fields,
        mode,
        kind,
        int64,
        what,
        if (kind == "value") skipped
      )
    })
  }
  num_records <- int64_values(
    lapply(seq_along(parsed), function(i) parsed[[i]][["numRecords"]]),
    int64,
    "a file's `numRecords`"
  )
  cardinality <- int64_values(
    lapply(actions, function(a) a[["deletionVector"]][["cardinality"]]),
    int64,
    "a deletion vector's `cardinality`"
  )
  check_record_counts(num_records, cardinality, paths)
  out <- list(
    num_records = num_records,
    null_count = obj("nullCount", "count"),
    min = obj("minValues", "value"),
    max = obj("maxValues", "value")
  )
  for (column in names(skipped$values)) {
    warn_int64(skipped$values[[column]], column, skipped$paths[[column]], int64)
  }
  out
}

# A `long` statistic the `int64` mode cannot hold, shown as NA: one warning
# per column, giving the first such value and the file it came from. The
# exact digits stay in the `action` column's `stats` string.
warn_int64 <- function(value, column, path, int64) {
  limit <- if (int64 == "double") {
    "a double holds integers exactly up to 2^53 - 1; `int64 = \"integer64\"` holds more"
  } else {
    "an integer64 holds -2^63 + 1 to 2^63 - 1"
  }
  zulake_warn(
    "int64",
    sprintf(
      paste(
        "The `long` statistics of column %s include %s (file %s), shown as NA:",
        "%s. The exact value stays in `action`."
      ),
      format_string(column),
      value,
      format_string(path),
      limit
    ),
    value = value,
    column = column,
    path = path
  )
}

# A file's `numRecords` is never negative, and its deletion vector deletes
# no more rows than it has, nor fewer than none: either would make a count
# no table can have (#59). NA (no statistic, no vector) is not checked.
check_record_counts <- function(records, cardinality, paths) {
  bad <- function(why, i) {
    zulake_abort(
      "corrupt_log",
      sprintf("file %s %s.", format_string(paths[i]), why),
      file = paths[i]
    )
  }
  num <- function(x) {
    if (inherits(x, "integer64")) as.character(x) else format_number(x)
  }
  neg <- which(!is.na(records) & records < 0)
  if (length(neg)) {
    bad(
      sprintf("has a negative `numRecords` (%s)", num(records[neg[1L]])),
      neg[1L]
    )
  }
  neg <- which(!is.na(cardinality) & cardinality < 0)
  if (length(neg)) {
    bad(
      sprintf(
        "has a deletion vector of negative `cardinality` (%s)",
        num(cardinality[neg[1L]])
      ),
      neg[1L]
    )
  }
  over <- which(!is.na(records) & !is.na(cardinality) & cardinality > records)
  if (length(over)) {
    i <- over[1L]
    bad(
      sprintf(
        "has a deletion vector of %s rows, more than its %s records",
        num(cardinality[i]),
        num(records[i])
      ),
      i
    )
  }
  invisible()
}

# numRecords and deletion vector cardinalities of the live files, summed:
# `records` (NA when a file has no numRecords), `deleted`, `without_records`
# and `with_dv` (numbers of files).
file_counts <- function(tbl, int64) {
  actions <- tbl$files$action
  paths <- tbl$files$path
  parsed <- parse_stats(file_stats_text(actions), paths)
  records <- int64_values(
    lapply(parsed, function(p) p[["numRecords"]]),
    int64,
    "a file's `numRecords`"
  )
  dvs <- lapply(actions, function(a) a[["deletionVector"]])
  has_dv <- !vapply(dvs, is.null, NA)
  deleted <- int64_values(
    lapply(dvs, function(d) d[["cardinality"]]),
    int64,
    "a deletion vector's `cardinality`"
  )
  missing_dv <- has_dv & is.na(deleted)
  if (any(missing_dv)) {
    zulake_abort(
      "corrupt_log",
      sprintf(
        "file %s has a deletion vector without a `cardinality`.",
        format_string(paths[missing_dv][1L])
      ),
      file = paths[missing_dv][1L]
    )
  }
  no_records <- is.na(records)
  bad <- has_dv & no_records
  if (any(bad)) {
    zulake_abort(
      "corrupt_log",
      sprintf(
        paste(
          "file %s has a deletion vector but no `numRecords` statistic, which the",
          "protocol requires with one."
        ),
        format_string(paths[bad][1L])
      ),
      file = paths[bad][1L]
    )
  }
  check_record_counts(records, deleted, paths)
  deleted[!has_dv] <- 0
  total_deleted <- int64_sum(deleted, int64, "The number of deleted rows")
  total <- if (any(no_records)) {
    if (int64 == "integer64") bit64::as.integer64(NA) else NA_real_
  } else {
    int64_sum(records, int64, "The number of records") - total_deleted
  }
  list(
    records = total,
    deleted = total_deleted,
    without_records = sum(no_records),
    with_dv = sum(has_dv),
    per_file = records,
    missing = which(no_records)
  )
}

# A deletion vector descriptor with all five of its fields, `NULL` where the
# log has none (`offset` for an inline vector), or `NULL` for no vector.
dv_descriptor <- function(dv, int64) {
  if (is.null(dv)) {
    return(NULL)
  }
  num <- function(name) {
    v <- dv[[name]]
    if (is.null(v)) {
      NULL
    } else {
      int64_values(list(v), int64, sprintf("a deletion vector's `%s`", name))
    }
  }
  list(
    storageType = dv[["storageType"]],
    pathOrInlineDv = dv[["pathOrInlineDv"]],
    offset = num("offset"),
    sizeInBytes = num("sizeInBytes"),
    cardinality = num("cardinality")
  )
}

logical_field <- function(actions, name) {
  vapply(
    actions,
    function(a) {
      v <- a[[name]]
      if (is.logical(v) && length(v) == 1L) v else NA
    },
    NA,
    USE.NAMES = FALSE
  )
}

# A map of strings (partition values) as a named character vector, NA for
# null.
string_map <- function(x) {
  if (!length(x)) {
    return(structure(character(), names = character()))
  }
  vapply(x, function(v) if (is.null(v)) NA_character_ else as.character(v), "")
}

# Where each file is: an absolute path or URI as the log gives it, or the
# table's location joined with the relative path, which the log writes
# percent-encoded (the protocol's "Path" rules).
file_uri <- function(tbl, paths) {
  absolute <- vapply(paths, is_absolute_path, NA, USE.NAMES = FALSE)
  out <- paths
  rel <- !absolute
  out[rel] <- paste0(
    sub("/+$", "", tbl$storage$root),
    "/",
    percent_decode(paths[rel])
  )
  out
}

# Percent-decoding of paths the log, a URI or Azure's listing gives. A
# decoded NUL or bytes that are not UTF-8 are a classed error, of `class`
# (#49): "corrupt_log" for the log's paths, "uri" for a user's URI,
# "storage" for Azure's answers.
percent_decode <- function(x, class = "corrupt_log") {
  vapply(
    x,
    function(s) {
      if (!grepl("%", s, fixed = TRUE)) {
        return(s)
      }
      m <- gregexpr("%[0-9A-Fa-f]{2}", s)
      pieces <- regmatches(s, m, invert = TRUE)[[1L]]
      codes <- regmatches(s, m)[[1L]]
      bytes <- raw()
      for (i in seq_along(pieces)) {
        bytes <- c(bytes, charToRaw(pieces[i]))
        if (i <= length(codes)) {
          bytes <- c(bytes, as.raw(strtoi(substring(codes[i], 2L), 16L)))
        }
      }
      if (any(bytes == as.raw(0L))) {
        zulake_abort(
          class,
          sprintf("the path %s decodes to a NUL byte.", format_string(s)),
          path = s
        )
      }
      out <- rawToChar(bytes)
      Encoding(out) <- "UTF-8"
      if (!validUTF8(out)) {
        zulake_abort(
          class,
          sprintf(
            "the path %s does not decode to UTF-8 text.",
            format_string(s)
          ),
          path = s
        )
      }
      out
    },
    "",
    USE.NAMES = FALSE
  )
}

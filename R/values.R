# Values in the log, typed by the table's schema (design section 7):
# partition values (strings in `add.partitionValues`) and statistics (the
# `stats` JSON string).

# ---- schema --------------------------------------------------------------

# The top-level fields of the snapshot's schema.
schema_fields <- function(tbl) {
  tbl$metadata[["schema"]][["fields"]]
}

field_name <- function(field) {
  if (is.list(field) && is_string(field[["name"]])) field[["name"]] else NA_character_
}

# A field's name in the data files: its column mapping physical name when the
# table maps columns, its name otherwise.
field_physical <- function(field, mode) {
  if (mode != "none") {
    md <- field[["metadata"]]
    physical <- if (is.list(md)) md[["delta.columnMapping.physicalName"]]
    if (is_string(physical)) {
      return(physical)
    }
  }
  field_name(field)
}

# "long", "decimal(10,2)", or "struct", "array", "map" for a nested type.
field_type <- function(field) {
  type <- field[["type"]]
  if (is_string(type)) {
    return(type)
  }
  if (is.list(type) && is_string(type[["type"]])) {
    return(type[["type"]])
  }
  NA_character_
}

# ---- text to typed values ------------------------------------------------

# "2024-01-05 10:00:00", "2024-01-05T10:00:00.123456Z" or with an offset
# ("+01:00"), as POSIXct in UTC, to the microsecond. `NA` for a value that
# is not a time; the callers decide what that means.
parse_time_text <- function(x, zone = TRUE) {
  re <- paste0(
    "^([0-9]{4,})-([0-9]{1,2})-([0-9]{1,2})[ T]([0-9]{1,2}):([0-9]{2}):([0-9]{2})",
    "([.][0-9]{1,9})?",
    if (zone) "(Z|[+-][0-9]{2}:?[0-9]{2})?" else "()",
    "$"
  )
  out <- rep(NA_real_, length(x))
  ok <- !is.na(x) & grepl(re, x)
  if (any(ok)) {
    y <- x[ok]
    part <- function(i) sub(re, sprintf("\\%d", as.integer(i)), y)
    days <- as.numeric(as.Date(sprintf("%s-%s-%s", part(1), part(2), part(3)), format = "%Y-%m-%d"))
    secs <- as.numeric(part(4)) * 3600 + as.numeric(part(5)) * 60 + as.numeric(part(6))
    frac <- part(7)
    us <- ifelse(nzchar(frac), round(as.numeric(paste0("0", frac)) * 1e6), 0)
    off <- part(8)
    off_secs <- rep(0, length(y))
    has_off <- nzchar(off) & off != "Z"
    if (any(has_off)) {
      o <- gsub(":", "", off[has_off], fixed = TRUE)
      sign <- ifelse(startsWith(o, "-"), -1, 1)
      off_secs[has_off] <- sign * (as.numeric(substr(o, 2L, 3L)) * 3600 + as.numeric(substr(o, 4L, 5L)) * 60)
    }
    out[ok] <- (days * 86400 + secs - off_secs) + us / 1e6
  }
  structure(out, class = c("POSIXct", "POSIXt"), tzone = "UTC")
}

parse_date_text <- function(x) {
  out <- rep(NA_real_, length(x))
  ok <- !is.na(x) & grepl("^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$", x)
  out[ok] <- as.numeric(as.Date(x[ok], format = "%Y-%m-%d"))
  structure(out, class = "Date")
}

# Partition values (character, NA for null) of one column as its Delta type
# says (the protocol's "Partition Value Serialization"): integers (`byte`,
# `short`) and doubles (`integer`, which an R integer cannot hold at -2^31,
# `float`, `double`), logicals, Dates and POSIXct; `long` as 64-bit values (int64.R); decimals,
# strings and binary as their text. Stage 2 checked every live value against
# its type, so a value that does not parse here is a corrupt log.
parse_partition_values <- function(x, type, int64, column) {
  what <- sprintf("partition column %s", format_string(column))
  out <- switch(type,
    byte = ,
    short = suppressWarnings(as.integer(x)),
    integer = whole_double(x),
    long = int64_values(as.list(ifelse(is.na(x), NA, paste0(num_mark, sub("^[+]", "", x)))), int64, what),
    float = ,
    double = partition_double(x),
    boolean = ifelse(is.na(x), NA, tolower(x) == "true"),
    date = parse_date_text(x),
    timestamp = parse_time_text(x, zone = TRUE),
    timestamp_ntz = parse_time_text(x, zone = FALSE),
    x
  )
  bad <- !is.na(x) & is.na(out) & !(type %in% c("float", "double") & x == "NaN")
  if (any(bad)) {
    zulake_abort(
      "corrupt_log",
      sprintf("partition value %s of column %s is not a %s.", format_string(x[bad][1L]), format_string(column), type),
      column = column
    )
  }
  out
}

# 32-bit integers as doubles: an R integer cannot hold -2^31.
whole_double <- function(x) {
  out <- suppressWarnings(as.numeric(x))
  out[!is.na(out) & out != trunc(out)] <- NA
  out
}

partition_double <- function(x) {
  y <- sub("^[+]", "", x)
  y[y == "Infinity"] <- "Inf"
  y[y == "-Infinity"] <- "-Inf"
  suppressWarnings(as.numeric(y))
}

# The typed partition values of `actions` (add or remove actions), one
# column per partition column, by logical name, as a data frame.
partition_table <- function(actions, tbl, int64) {
  columns <- tbl$metadata[["partitionColumns"]]
  types <- column_types(tbl)
  out <- list()
  for (col in columns) {
    out[[col]] <- parse_partition_values(partition_raw(actions, tbl, col), types[[col]], int64, col)
  }
  new_data_frame_n(out, length(actions))
}

# The partition values of column `col` in `actions` as the log writes them,
# NA for null (an empty string or a missing key).
partition_raw <- function(actions, tbl, col) {
  fields <- schema_fields(tbl)
  field <- fields[[match(col, vapply(fields, field_name, ""))]]
  key <- field_physical(field, tbl$column_mapping)
  vapply(actions, function(a) {
    v <- a[["partitionValues"]][[key]]
    if (is.null(v) || !nzchar(v)) NA_character_ else v
  }, "", USE.NAMES = FALSE)
}

# Partition columns `columns` of `actions` typed as a read returns them:
# as partition_table() does, except that a decimal of precision 15 or less
# is a double (design section 7).
partition_read_table <- function(actions, tbl, int64, columns) {
  types <- column_types(tbl)
  out <- list()
  for (col in columns) {
    raw <- partition_raw(actions, tbl, col)
    ps <- decimal_ps(types[[col]])
    out[[col]] <- if (!is.null(ps) && ps[["precision"]] <= max_double_precision) {
      as.numeric(raw)
    } else {
      parse_partition_values(raw, types[[col]], int64, col)
    }
  }
  new_data_frame_n(out, length(actions))
}

new_data_frame_n <- function(cols, n) {
  structure(cols, names = names(cols) %||% character(), class = "data.frame", row.names = .set_row_names(n))
}

`%||%` <- function(x, y) if (is.null(x)) y else x

# Row `i` of a data frame of typed columns, as a named list of scalars.
frame_row <- function(df, i) {
  out <- lapply(df, function(col) col[i])
  if (!length(out)) structure(list(), names = character()) else out
}

# ---- statistics ----------------------------------------------------------

# `stats` strings (NA where a file has none) parsed with every number kept
# as text (int64.R). A string that is not JSON is a corrupt log.
parse_stats <- function(stats, paths) {
  out <- vector("list", length(stats))
  have <- !is.na(stats)
  if (!any(have)) {
    return(out)
  }
  marked <- mark_numbers(stats[have], all = TRUE)
  idx <- which(have)
  for (k in seq_along(idx)) {
    i <- idx[k]
    x <- tryCatch(
      zujson::json_parse(marked[k]),
      zujson_error = function(e) {
        zulake_abort(
          "corrupt_log",
          sprintf("the statistics of file %s are not valid JSON: %s", format_string(paths[i]), conditionMessage(e)),
          file = paths[i],
          parent = e
        )
      }
    )
    if (!is.list(x) || (length(x) && is.null(names(x)))) {
      zulake_abort("corrupt_log", sprintf("the statistics of file %s are not a JSON object.", format_string(paths[i])), file = paths[i])
    }
    out[[i]] <- x
  }
  out
}

# One statistics object (`minValues`, `maxValues` or `nullCount`) with its
# keys turned from physical to logical names and its values typed by the
# schema: `kind = "value"` types each leaf by its column, `kind = "count"`
# reads every leaf as a 64-bit count. Decimals stay their JSON text (D10).
# A `long` value the `int64` mode cannot hold is NA when `skipped` is an
# environment, recorded there as `skipped$values[[column]]`; `prefix` is the
# column path of a nested object.
stats_object <- function(x, fields, mode, kind, int64, what, skipped = NULL, prefix = "") {
  if (is.null(x)) {
    return(NULL)
  }
  if (!is.list(x) || (length(x) && is.null(names(x)))) {
    zulake_abort("corrupt_log", sprintf("%s is not a JSON object.", what))
  }
  if (!length(x)) {
    return(structure(list(), names = character()))
  }
  physical <- vapply(fields, field_physical, "", mode = mode)
  out <- vector("list", length(x))
  out_names <- names(x)
  for (j in seq_along(x)) {
    i <- match(names(x)[j], physical)
    field <- if (!is.na(i)) fields[[i]]
    if (!is.null(field)) {
      out_names[j] <- field_name(field)
    }
    v <- x[[j]]
    leaf_what <- sprintf("%s of column %s", what, format_string(out_names[j]))
    sub_fields <- if (!is.null(field) && identical(field_type(field), "struct")) field[["type"]][["fields"]]
    if (is.list(v) && !is.null(names(v))) {
      out[j] <- list(stats_object(v, sub_fields %||% list(), mode, kind, int64, leaf_what, skipped,
                                  paste0(prefix, out_names[j], ".")))
    } else if (kind == "count") {
      out[j] <- list(int64_values(list(v), int64, leaf_what))
    } else {
      type <- if (is.null(field)) NA_character_ else field_type(field)
      out[j] <- list(if (identical(type, "long") && is.environment(skipped)) {
        tryCatch(stats_leaf(v, type, int64, leaf_what), zulake_error_int64 = function(e) {
          column <- paste0(prefix, out_names[j])
          if (is.null(skipped$values[[column]])) {
            skipped$values[[column]] <- e$value
            skipped$paths[[column]] <- skipped$path
          }
          if (int64 == "integer64") bit64::as.integer64(NA) else NA_real_
        })
      } else {
        stats_leaf(v, type, int64, leaf_what)
      })
    }
  }
  names(out) <- out_names
  out
}

stats_leaf <- function(v, type, int64, what) {
  text <- if (is_marked(v)) marked_text(v) else v
  if (is.null(v)) {
    text <- NA
  }
  if (is.na(type)) {
    # A key the schema does not have: numbers as numbers, the rest as given.
    if (is_marked(v)) {
      return(if (grepl("^-?[0-9]+$", text)) int64_values(list(v), int64, what) else as.numeric(text))
    }
    return(if (is.null(v)) NA else unmark_tree(v, int64, what))
  }
  if (grepl("^decimal", type)) {
    return(if (is.na(text)) NA_character_ else as.character(text))
  }
  out <- switch(type,
    byte = ,
    short = suppressWarnings(as.integer(text)),
    integer = whole_double(as.character(text)),
    long = int64_values(list(v), int64, what),
    float = ,
    double = suppressWarnings(as.numeric(text)),
    date = parse_date_text(as.character(text)),
    timestamp = parse_time_text(as.character(text), zone = TRUE),
    timestamp_ntz = parse_time_text(as.character(text), zone = FALSE),
    return(if (is.null(v)) NA else unmark_tree(v, int64, what))
  )
  if (!is.na(text) && is.na(out)) {
    zulake_abort("corrupt_log", sprintf("%s is %s, which is not a %s.", what, format_string(as.character(text)), type))
  }
  out
}

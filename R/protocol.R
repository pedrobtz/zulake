# The reader-feature gate (D7) and the checks that need the final metadata.

# Reader features zulake supports (design section 2). Every other name in
# `readerFeatures`, known to the protocol or not, is refused by name:
# reading past one silently returns wrong rows. `columnMapping` is supported
# in `name` mode only.
supported_reader_features <- c("columnMapping", "deletionVectors", "timestampNtz", "v2Checkpoint")

max_reader_version <- 3

# Refuses a snapshot zulake cannot read correctly, naming what it lacks.
# Called on the replayed protocol and metadata, before anything outside
# `_delta_log/` is read.
check_reader_features <- function(protocol, metadata, version) {
  reader <- protocol[["minReaderVersion"]]
  if (reader > max_reader_version || reader < 1) {
    refuse_feature(
      sprintf("readerVersion %s", format_number(reader)),
      sprintf("reader version %s", format_number(reader)),
      version
    )
  }
  features <- reader_features(protocol)
  unknown <- setdiff(features, supported_reader_features)
  if (length(unknown)) {
    refuse_feature(unknown, sprintf("reader feature %s", paste(format_string(unknown), collapse = ", ")), version)
  }
  mode <- column_mapping_mode(protocol, metadata)
  if (!mode %in% c("none", "name")) {
    refuse_feature(
      "columnMapping",
      sprintf("column mapping in %s mode (only \"name\" mode is supported)", format_string(mode)),
      version
    )
  }
  invisible()
}

refuse_feature <- function(feature, what, version) {
  zulake_abort(
    "unsupported_feature",
    sprintf("Version %s of this table needs %s, which zulake does not support.", format_number(version), what),
    feature = feature,
    version = version
  )
}

reader_features <- function(protocol) {
  if (protocol[["minReaderVersion"]] < 3) {
    return(character())
  }
  as.character(protocol[["readerFeatures"]])
}

# `delta.columnMapping.mode`, honoured only when the protocol supports
# column mapping (reader version 2, or 3 with the feature); "none" otherwise.
column_mapping_mode <- function(protocol, metadata) {
  reader <- protocol[["minReaderVersion"]]
  on <- reader == 2 || (reader == 3 && "columnMapping" %in% reader_features(protocol))
  mode <- metadata[["configuration"]][["delta.columnMapping.mode"]]
  if (!on || is.null(mode)) "none" else mode
}

# ---- partition values ----------------------------------------------------

# Every live file's partition values are what the column's Delta type
# allows, serialised as the protocol's "Partition Value Serialization" says.
# A value of the wrong type is a corrupt log, never a value to guess at.
check_partition_values <- function(adds, metadata, mode) {
  columns <- metadata[["partitionColumns"]]
  if (!length(columns) || !length(adds)) {
    return(invisible())
  }
  fields <- metadata[["schema"]][["fields"]]
  field_names <- vapply(fields, function(f) {
    if (is.list(f) && is_string(f[["name"]])) f[["name"]] else NA_character_
  }, "")
  for (col in columns) {
    i <- match(col, field_names)
    if (is.na(i)) {
      zulake_abort(
        "corrupt_log",
        sprintf("partition column %s is not in the table's schema.", format_string(col))
      )
    }
    field <- fields[[i]]
    key <- col
    if (mode != "none") {
      md <- field[["metadata"]]
      physical <- if (is.list(md)) md[["delta.columnMapping.physicalName"]]
      if (is_string(physical)) key <- physical
    }
    type <- field[["type"]]
    if (!is_string(type)) {
      zulake_abort("corrupt_log", sprintf("partition column %s is not of a primitive type.", format_string(col)))
    }
    for (a in adds) {
      value <- a[["partitionValues"]][[key]]
      if (is.null(value) || !nzchar(value)) next
      if (!partition_value_ok(value, type)) {
        zulake_abort(
          "corrupt_log",
          sprintf(
            "file %s has partition value %s for column %s, which is not a %s.",
            format_string(a[["path"]]), format_string(value), format_string(col), type
          ),
          file = a[["path"]],
          column = col
        )
      }
    }
  }
  invisible()
}

integer_limits <- list(
  byte = c("-128", "127"),
  short = c("-32768", "32767"),
  integer = c("-2147483648", "2147483647"),
  long = c("-9223372036854775808", "9223372036854775807")
)

partition_value_ok <- function(x, type) {
  number <- "^[+-]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][+-]?[0-9]+)?$"
  date <- "[0-9]{4,}-[0-9]{1,2}-[0-9]{1,2}"
  time <- "[0-9]{1,2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,9})?"
  if (type %in% names(integer_limits)) {
    return(integer_in_range(x, integer_limits[[type]]))
  }
  switch(type,
    string = ,
    binary = TRUE,
    boolean = tolower(x) %in% c("true", "false"),
    float = ,
    double = grepl(number, x) || x %in% c("NaN", "Infinity", "-Infinity", "+Infinity"),
    date = grepl(paste0("^", date, "$"), x) && date_parts_ok(x),
    timestamp = grepl(paste0("^", date, "[ T]", time, "(Z|[+-][0-9]{2}:?[0-9]{2})?$"), x) && date_parts_ok(x),
    timestamp_ntz = grepl(paste0("^", date, "[ T]", time, "$"), x) && date_parts_ok(x),
    if (grepl("^decimal[(]", type)) grepl(number, x) else TRUE
  )
}

# Decimal digits within [lo, hi], compared as text so no value rounds.
integer_in_range <- function(x, limits) {
  if (!grepl("^[+-]?[0-9]+$", x)) {
    return(FALSE)
  }
  neg <- startsWith(x, "-")
  digits <- sub("^[+-]?0*", "", x)
  bound <- sub("^-", "", limits[if (neg) 1L else 2L])
  nchar(digits) < nchar(bound) || (nchar(digits) == nchar(bound) && !sorts_after(digits, bound))
}

# Month 1-12 and day 1-31 in a value that starts YYYY-MM-DD.
date_parts_ok <- function(x) {
  parts <- strsplit(sub("[ T].*$", "", x), "-", fixed = TRUE)[[1L]]
  month <- as.integer(parts[2L])
  day <- as.integer(parts[3L])
  month >= 1L && month <= 12L && day >= 1L && day <= 31L
}

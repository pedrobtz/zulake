# The reader-feature gate (D7) and the checks that need the final metadata.

# Reader features zulake supports (design section 2 and the D7 amendment of
# 2026-11-26): a reader feature is accepted only when the protocol's reader
# requirements for it are implemented, or are empty. `vacuumProtocolCheck`
# asks readers for nothing but to acknowledge it. `columnMapping` is
# supported in `name` mode only. Every other name in `readerFeatures`, known
# to the protocol or not, is refused by name: reading past one silently
# returns wrong rows. `writerFeatures` is never consulted here: zulake does
# not write.
supported_reader_features <- c(
  "columnMapping",
  "deletionVectors",
  "timestampNtz",
  "v2Checkpoint",
  "vacuumProtocolCheck"
)

# Reader features the protocol defines that zulake refuses, and why. Names
# not here and not supported are refused as unknown.
refused_reader_features <- c(
  catalogManaged = "a catalog to resolve commits",
  typeWidening = "values converted to their widened type",
  `typeWidening-preview` = "values converted to their widened type",
  variantType = "variant values decoded",
  `variantType-preview` = "variant values decoded",
  variantShredding = "shredded variant values decoded",
  `variantShredding-preview` = "shredded variant values decoded"
)

max_reader_version <- 3

# Refuses a snapshot zulake cannot read correctly, naming what it lacks.
# Called on the replayed protocol and metadata, before anything outside
# `_delta_log/` is read. The condition carries `protocol`, the
# lake_protocol() frame, with each requirement marked supported or not.
check_reader_features <- function(protocol, metadata, version) {
  reader <- protocol[["minReaderVersion"]]
  if (reader > max_reader_version || reader < 1) {
    refuse_feature(
      sprintf("readerVersion %s", format_number(reader)),
      sprintf("reader version %s", format_number(reader)),
      version,
      protocol,
      metadata
    )
  }
  features <- reader_features(protocol)
  unknown <- setdiff(features, supported_reader_features)
  if (length(unknown)) {
    refuse_feature(
      unknown,
      paste("reader feature", paste(feature_label(unknown), collapse = ", ")),
      version,
      protocol,
      metadata
    )
  }
  # A mode set where the protocol does not declare column mapping: the
  # files hold physical names a reader by logical names would never find,
  # so every value would read as NA (#58). deltalake refuses it too.
  set <- metadata[["configuration"]][["delta.columnMapping.mode"]]
  if (is_string(set) && set != "none" && !column_mapping_declared(protocol)) {
    refuse_feature(
      "columnMapping",
      sprintf(
        "column mapping (its %s mode is set, but its protocol does not declare the feature)",
        format_string(set)
      ),
      version,
      protocol,
      metadata
    )
  }
  mode <- column_mapping_mode(protocol, metadata)
  if (!mode %in% c("none", "name")) {
    refuse_feature(
      "columnMapping",
      sprintf(
        "column mapping in %s mode (only \"name\" mode is supported)",
        format_string(mode)
      ),
      version,
      protocol,
      metadata
    )
  }
  invisible()
}

# "\"typeWidening\" (it needs values converted to their widened type)", or
# the quoted name alone for a feature the package does not know.
feature_label <- function(features) {
  why <- unname(refused_reader_features[features])
  ifelse(
    is.na(why),
    format_string(features),
    sprintf("%s (it needs %s)", format_string(features), why)
  )
}

refuse_feature <- function(feature, what, version, protocol, metadata) {
  zulake_abort(
    "unsupported_feature",
    sprintf(
      "Version %s of this table needs %s, which zulake does not support.",
      format_number(version),
      what
    ),
    feature = feature,
    version = version,
    protocol = protocol_frame(protocol, metadata)
  )
}

# The protocol as lake_protocol() returns it: one row per requirement, the
# reader and writer versions first, then each feature, with `reader` and
# `writer` saying which list names it and `supported` whether zulake reads a
# table that needs it. Writer requirements are always supported: zulake does
# not write, so they are never a reason to refuse.
protocol_frame <- function(protocol, metadata) {
  reader <- protocol[["minReaderVersion"]]
  rf <- reader_features(protocol)
  wf <- if (protocol[["minWriterVersion"]] >= 7) {
    as.character(protocol[["writerFeatures"]])
  } else {
    character()
  }
  features <- unique(c(rf, wf))
  mode <- column_mapping_mode(protocol, metadata)
  in_reader <- features %in% rf
  ok <- !in_reader | features %in% supported_reader_features
  ok[features == "columnMapping" & in_reader] <- mode %in% c("none", "name")
  new_data_frame(list(
    name = c("readerVersion", "writerVersion", features),
    reader = c(TRUE, FALSE, in_reader),
    writer = c(FALSE, TRUE, features %in% wf),
    version = c(
      as.numeric(reader),
      as.numeric(protocol[["minWriterVersion"]]),
      rep(NA_real_, length(features))
    ),
    supported = c(reader >= 1 && reader <= max_reader_version, TRUE, ok)
  ))
}

reader_features <- function(protocol) {
  if (protocol[["minReaderVersion"]] < 3) {
    return(character())
  }
  as.character(protocol[["readerFeatures"]])
}

# `delta.columnMapping.mode`, honoured only when the protocol supports
# column mapping (reader version 2, or 3 with the feature); "none" otherwise,
# where check_reader_features() refuses any mode but "none".
column_mapping_mode <- function(protocol, metadata) {
  mode <- metadata[["configuration"]][["delta.columnMapping.mode"]]
  if (!column_mapping_declared(protocol) || is.null(mode)) "none" else mode
}

# Whether the protocol declares column mapping for readers: reader version
# 2, or 3 with the reader feature.
column_mapping_declared <- function(protocol) {
  reader <- protocol[["minReaderVersion"]]
  reader == 2 || (reader == 3 && "columnMapping" %in% reader_features(protocol))
}

# In name mode every top-level field has a physical name, as the protocol
# requires: falling back to the logical name could read another column's
# data after a rename (#77). Nested fields are not read (D14).
check_physical_names <- function(metadata, mode) {
  if (mode != "name") {
    return(invisible())
  }
  for (field in metadata[["schema"]][["fields"]]) {
    if (is.na(field_physical_name(field))) {
      name <- field_name(field)
      zulake_abort(
        "corrupt_log",
        sprintf(
          paste(
            "field %s has no `delta.columnMapping.physicalName`, which column",
            "mapping in \"name\" mode requires."
          ),
          format_string(name)
        ),
        column = name
      )
    }
  }
  invisible()
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
  for (col in columns) {
    field <- field_by_name(fields, col)
    if (is.null(field)) {
      zulake_abort(
        "corrupt_log",
        sprintf(
          "partition column %s is not in the table's schema.",
          format_string(col)
        )
      )
    }
    key <- field_physical(field, mode)
    type <- field[["type"]]
    if (!is_string(type)) {
      zulake_abort(
        "corrupt_log",
        sprintf(
          "partition column %s is not of a primitive type.",
          format_string(col)
        )
      )
    }
    for (a in adds) {
      value <- a[["partitionValues"]][[key]]
      if (is.null(value) || !nzchar(value)) {
        next
      }
      if (!partition_value_ok(value, type)) {
        zulake_abort(
          "corrupt_log",
          sprintf(
            "file %s has partition value %s for column %s, which is not a %s.",
            format_string(a[["path"]]),
            format_string(value),
            format_string(col),
            type
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

# Whether a partition value parses as its column's type; dates and times
# through the parsers that later convert them, so that a value accepted here
# always converts (#53).
partition_value_ok <- function(x, type) {
  number <- "^[+-]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][+-]?[0-9]+)?$"
  if (type %in% names(integer_limits)) {
    return(integer_in_range(x, integer_limits[[type]]))
  }
  switch(
    type,
    string = ,
    binary = TRUE,
    boolean = tolower(x) %in% c("true", "false"),
    float = ,
    double = grepl(number, x) ||
      is.nan(double_special(x)) ||
      is.infinite(double_special(x)),
    date = !is.na(parse_date_text(x)),
    timestamp = !is.na(parse_time_text(x, zone = TRUE)),
    timestamp_ntz = !is.na(parse_time_text(x, zone = FALSE)),
    if (grepl("^decimal[(]", type)) decimal_value_ok(x, type) else TRUE
  )
}

# Whether `x` is a decimal(p, s) partition value: digits, with a fraction
# of at most s digits after a point, an optional sign, and at most p - s
# digits before the point once leading zeros are dropped. No exponent, and
# a point has digits on both sides: what the comparator reads (compare.R),
# and a value the type holds (#112).
decimal_value_ok <- function(x, type) {
  ps <- decimal_ps(type)
  m <- regmatches(x, regexec("^[+-]?([0-9]+)(?:[.]([0-9]+))?$", x))[[1L]]
  if (is.null(ps) || length(m) != 3L) {
    return(FALSE)
  }
  int <- sub("^0+", "", m[2L])
  nchar(m[3L]) <= ps[["scale"]] &&
    nchar(int) <= ps[["precision"]] - ps[["scale"]]
}

# Decimal digits within [lo, hi], compared as text so no value rounds.
integer_in_range <- function(x, limits) {
  if (!grepl("^[+-]?[0-9]+$", x)) {
    return(FALSE)
  }
  neg <- startsWith(x, "-")
  digits <- sub("^[+-]?0*", "", x)
  bound <- sub("^-", "", limits[if (neg) 1L else 2L])
  nchar(digits) < nchar(bound) ||
    (nchar(digits) == nchar(bound) && !sorts_after(digits, bound))
}

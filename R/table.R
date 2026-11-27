#' The table: versions, metadata, schema, protocol
#'
#' Functions that describe the table a snapshot holds, each from the log
#' alone; none reads a data file.
#'
#' * `lake_versions()`: every version up to the snapshot's whose commit is
#'   still in the log, with its commit time.
#' * `lake_history()`: the `commitInfo` of those commits, newest first.
#' * `lake_metadata()`: the table's `metaData` action, in one row.
#' * `lake_schema()`: one row per top-level column.
#' * `lake_partition_columns()`: the partition columns, in order.
#' * `lake_properties()`: the table's configuration, with the defaults the
#'   protocol states filled in.
#' * `lake_protocol()`: the reader and writer versions and every feature,
#'   each marked supported or not.
#' * `lake_summary()`: one row of totals.
#'
#' The commit time of a version is the commit's in-commit timestamp when
#' the table records them, and the commit file's modification time
#' otherwise, as the protocol prescribes and as `lake_open(timestamp =)`
#' uses it. File times are made increasing first, as Delta and `deltalake`
#' make them: a commit whose file time is not after the previous commit's
#' counts as 1 millisecond after it.
#'
#' @inheritParams lake_files
#' @param limit The number of commits to return, newest first. `NULL`, the
#'   default, returns all of them.
#' @returns
#' `lake_versions()`: a data frame `version`, `timestamp` (`POSIXct`, UTC),
#' oldest first.
#'
#' `lake_history()`: a data frame `version`, `timestamp` (the commit time),
#' `operation` and `commit_info`, a list column holding each commit's
#' `commitInfo` action as the log writes it (`NULL` for a commit without
#' one), newest first.
#'
#' `lake_metadata()`: a data frame of one row: `id`, `name`, `description`,
#' `format_provider`, `format_options` (a list column), `created_time`
#' (`POSIXct`, or `NA`), `partition_columns` (a list column) and
#' `configuration` (a list column; see also `lake_properties()`).
#'
#' `lake_schema()`: a data frame `name`, `type` (the Delta type, such as
#' `"long"`, `"decimal(10,2)"` or `"timestamp_ntz"`, which is the zone-less
#' timestamp; `"struct"`, `"array"` or `"map"` for a nested column),
#' `nullable`, `partition` (whether it is a partition column),
#' `physical_name` (its name in the data files under column mapping, `NA`
#' otherwise), `metadata` and `type_detail` (list columns: the column's
#' metadata, and the nested type as the log writes it, `NULL` for a
#' primitive one).
#'
#' `lake_partition_columns()`: a character vector.
#'
#' `lake_properties()`: a data frame `key`, `value` and `default` (`TRUE`
#' for a property the table does not set, filled in with the protocol's
#' default), sorted by key.
#'
#' `lake_protocol()`: a data frame with one row per requirement: first
#' `readerVersion` and `writerVersion` with their `version`, then each
#' feature, with `reader` and `writer` saying which list of the protocol
#' names it, and `supported`, whether zulake reads a table that needs it.
#' Writer requirements are always supported: zulake does not write. A
#' snapshot only exists for a table zulake can read, so every row of a
#' snapshot's protocol is supported; the `zulake_error_unsupported_feature`
#' error of a table that is refused carries the same data frame in its
#' `protocol` field.
#'
#' `lake_summary()`: a data frame of one row: `version`, `timestamp`,
#' `files`, `bytes`, `records` (as [lake_count()] counts them, `NA` when a
#' file has no `numRecords`), `deleted_rows` (the cardinality of the
#' deletion vectors), `files_with_deletion_vectors` and
#' `files_without_records`.
#' @seealso [lake_files()] for the files, [lake_actions()] for a commit's
#'   actions.
#' @export
#' @examples
#' # The example table the package ships: orders partitioned by region, five versions.
#' path <- system.file("extdata", "orders", package = "zulake")
#' tbl <- lake_open(path)
#' lake_versions(tbl)
#' lake_history(tbl, limit = 2)[c("version", "timestamp", "operation")]
#' lake_metadata(tbl)[c("name", "description", "created_time")]
#' lake_schema(tbl)[c("name", "type", "nullable", "partition")]
#' lake_partition_columns(tbl)
#' props <- lake_properties(tbl)
#' props[!props$default, ]  # the ones the table sets
#' lake_protocol(tbl)
#' lake_summary(tbl)
lake_versions <- function(tbl) {
  check_table(tbl)
  commits <- snapshot_commits(tbl)
  new_data_frame(list(version = commits$version, timestamp = commit_times(tbl, commits)))
}

#' @rdname lake_versions
#' @export
lake_history <- function(tbl, limit = NULL, int64 = c("double", "integer64")) {
  check_table(tbl)
  int64 <- check_int64(int64)
  limit <- arg_number(limit)
  if (!is.null(limit) && (!is_whole(limit) || limit < 0)) {
    zulake_abort("argument", "`limit` must be NULL or a whole number of 0 or more.")
  }
  commits <- snapshot_commits(tbl)
  commits <- commits[rev(seq_len(nrow(commits))), , drop = FALSE]
  if (!is.null(limit) && limit < nrow(commits)) {
    commits <- commits[seq_len(limit), , drop = FALSE]
  }
  info <- lapply(commits$name, function(name) {
    for (a in read_actions(tbl$storage, name)) {
      if (!is.null(a[["commitInfo"]])) {
        return(unmark_tree(a[["commitInfo"]], int64, sprintf("the `commitInfo` of %s", name)))
      }
    }
    NULL
  })
  operation <- vapply(info, function(x) {
    op <- if (is.list(x)) x[["operation"]]
    if (is_string(op)) op else NA_character_
  }, "")
  new_data_frame(list(
    version = version_column(commits$version, int64),
    timestamp = commit_times(tbl, commits),
    operation = operation,
    commit_info = info
  ))
}

#' @rdname lake_versions
#' @export
lake_metadata <- function(tbl) {
  check_table(tbl)
  m <- tbl$metadata
  str_or_na <- function(x) if (is_string(x)) x else NA_character_
  created <- m[["createdTime"]]
  created <- if (is.null(created)) NA_real_ else int64_values(list(created), "double", "the table's `createdTime`")
  fmt <- m[["format"]]
  new_data_frame(list(
    id = m[["id"]],
    name = str_or_na(m[["name"]]),
    description = str_or_na(m[["description"]]),
    format_provider = str_or_na(if (is.list(fmt)) fmt[["provider"]]),
    format_options = list(if (is.list(fmt) && is.list(fmt[["options"]])) fmt[["options"]] else named_list()),
    created_time = ms_to_posixct(created),
    partition_columns = list(m[["partitionColumns"]]),
    configuration = list(as.list(m[["configuration"]] %||% named_list()))
  ))
}

#' @rdname lake_versions
#' @export
lake_schema <- function(tbl) {
  check_table(tbl)
  fields <- schema_fields(tbl)
  mode <- tbl$column_mapping
  physical <- vapply(fields, field_physical, "", mode = mode)
  logical_names <- vapply(fields, field_name, "")
  new_data_frame(list(
    name = logical_names,
    type = vapply(fields, field_type, ""),
    nullable = vapply(fields, function(f) isTRUE(f[["nullable"]]), NA),
    partition = logical_names %in% tbl$metadata[["partitionColumns"]],
    physical_name = if (mode == "none") rep(NA_character_, length(fields)) else physical,
    metadata = lapply(fields, function(f) if (is.list(f[["metadata"]])) f[["metadata"]] else named_list()),
    type_detail = lapply(fields, function(f) if (is.list(f[["type"]])) f[["type"]] else NULL)
  ))
}

#' @rdname lake_versions
#' @export
lake_partition_columns <- function(tbl) {
  check_table(tbl)
  tbl$metadata[["partitionColumns"]]
}

# Table properties whose value when absent the protocol states (PROTOCOL.md
# at 483d55e: "Table Properties", "Column Mapping", "Append-only Tables",
# "Row Tracking", "Variant Shredding", "Checkpoint Format").
property_defaults <- c(
  delta.appendOnly = "false",
  delta.checkpoint.writeStatsAsJson = "true",
  delta.checkpoint.writeStatsAsStruct = "false",
  delta.columnMapping.mode = "none",
  delta.enableVariantShredding = "false",
  delta.parquet.compression.codec = "zstd",
  delta.parquet.format.version = "1.0.0",
  delta.rowTrackingSuspended = "false"
)

#' @rdname lake_versions
#' @export
lake_properties <- function(tbl) {
  check_table(tbl)
  conf <- tbl$metadata[["configuration"]]
  set <- if (length(conf)) vapply(conf, function(v) if (is.null(v)) NA_character_ else v, "") else character()
  absent <- setdiff(names(property_defaults), names(set))
  key <- c(names(set), absent)
  value <- c(unname(set), unname(property_defaults[absent]))
  default <- c(rep(FALSE, length(set)), rep(TRUE, length(absent)))
  ord <- order(key, method = "radix")
  new_data_frame(list(key = key[ord], value = value[ord], default = default[ord]))
}

#' @rdname lake_versions
#' @export
lake_protocol <- function(tbl) {
  check_table(tbl)
  protocol_frame(tbl$protocol, tbl$metadata)
}

#' @rdname lake_versions
#' @export
lake_summary <- function(tbl, int64 = c("double", "integer64")) {
  check_table(tbl)
  int64 <- check_int64(int64)
  counts <- file_counts(tbl, int64)
  sizes <- int64_values(lapply(tbl$files$action, function(a) a[["size"]]), int64, "an add's `size`")
  new_data_frame(list(
    version = version_column(tbl$version, int64),
    timestamp = tbl$timestamp,
    files = nrow(tbl$files),
    bytes = int64_sum(sizes, int64, "The table's size in bytes"),
    records = counts$records,
    deleted_rows = counts$deleted,
    files_with_deletion_vectors = counts$with_dv,
    files_without_records = counts$without_records
  ))
}

# ---- helpers -------------------------------------------------------------

# Versions as the `int64` argument asks: always exact, since the log's
# versions are below 2^53.
version_column <- function(v, int64) {
  if (int64 == "integer64") bit64::as.integer64(v) else v
}

# The commits of the log listing up to the snapshot's version, oldest first.
snapshot_commits <- function(tbl) {
  log <- tbl$log
  commits <- log[log$kind == "commit" & log$version <= tbl$version, , drop = FALSE]
  commits <- commits[order(commits$version), , drop = FALSE]
  row.names(commits) <- NULL
  commits
}

# Commit times of `commits` (rows of the snapshot's commits, in any order
# or a subset), as POSIXct in UTC; file times made increasing over all of
# the snapshot's commits.
commit_times <- function(tbl, commits) {
  ict <- ict_info(tbl$protocol, tbl$metadata)
  read <- function(name) read_actions(tbl$storage, name)
  commits_all <- snapshot_commits(tbl)
  ms <- commit_times_ms(commits_all, ict, read, match(commits$version, commits_all$version))
  ms_to_posixct(ms)
}

#' @export
format.zulake_table <- function(x, ...) {
  files <- nrow(x$files)
  # A print never fails on what the log holds: the zulake_error these catch
  # is a zulake_error_int64 (a size, numRecords or cardinality past 2^53 - 1,
  # which a double cannot sum exactly) or a zulake_error_corrupt_log
  # (statistics that are not JSON, a deletion vector of more rows than its
  # file), each shown as "unknown"; lake_summary() and lake_count() raise
  # them (#90).
  sizes <- tryCatch(
    int64_sum(
      int64_values(
        lapply(x$files$action, function(a) a[["size"]]),
        "double",
        "size"
      ),
      "double",
      "size"
    ),
    zulake_error = function(e) NA_real_
  )
  counts <- tryCatch(file_counts(x, "double"), zulake_error = function(e) NULL)
  records <- if (is.null(counts)) {
    "unknown (the statistics cannot be read)"
  } else if (counts$without_records) {
    sprintf(
      "unknown (%s files without numRecords)",
      format_number(counts$without_records)
    )
  } else {
    format_number(counts$records)
  }
  time <- if (is.na(x$timestamp)) {
    "unknown"
  } else {
    format(x$timestamp, "%Y-%m-%d %H:%M:%S UTC", tz = "UTC")
  }
  c(
    sprintf(
      "<zulake_table> %s table, version %s",
      x$format,
      format_number(x$version)
    ),
    sprintf("uri:       %s", x$uri),
    sprintf("committed: %s", time),
    sprintf(
      "files:     %s (%s bytes)",
      format_number(files),
      if (is.na(sizes)) "unknown" else format_number(sizes)
    ),
    sprintf("records:   %s", records)
  )
}

#' @export
print.zulake_table <- function(x, ...) {
  writeLines(format(x, ...))
  invisible(x)
}

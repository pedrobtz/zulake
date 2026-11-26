# Classed conditions.
#
# Every error zulake raises inherits from `zulake_error`, with one subclass
# per kind, so callers and tests catch by class and never by message:
#
#   zulake_error_argument              an argument of the wrong type or value
#   zulake_error_uri                   a URI zulake cannot open (scheme)
#   zulake_error_storage               a file the storage backend cannot read
#   zulake_error_not_table             no Delta log at the location
#   zulake_error_version               a version or timestamp the log lacks
#   zulake_error_corrupt_log           a log that breaks the protocol
#   zulake_error_checkpoint_unreadable a log that needs a checkpoint (D14)
#   zulake_error_unsupported_feature   a reader feature zulake refuses (D7);
#                                      the condition's `feature` field
#                                      names it, `protocol` holds the
#                                      lake_protocol() frame
#   zulake_error_int64                 a 64-bit value a double cannot hold
#                                      exactly (D10); `value` is its digits
#   zulake_error_filter                a filter outside the pruning subset
#
# and one warning, `zulake_warning_count_unknown` (class
# c("zulake_warning_count_unknown", "zulake_warning", "warning")), when
# lake_count() meets a file without `numRecords`; `files` counts them.
#
# Base R only: the package has no rlang or cli dependency.

zulake_abort <- function(class, message, ..., call = NULL) {
  cnd <- structure(
    class = c(paste0("zulake_error_", class), "zulake_error", "error", "condition"),
    list(message = message, call = call, ...)
  )
  stop(cnd)
}

# A number for a message, written in full whatever the session's `scipen`,
# `digits` or `OutDec` (sprintf() ignores all three).
format_number <- function(x) {
  sprintf("%.0f", x)
}

# A string for a message, quoted and escaped.
format_string <- function(x) {
  encodeString(enc2utf8(x), quote = "\"")
}

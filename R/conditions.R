# Classed conditions.
#
# Every error zulake raises inherits from `zulake_error`, with one subclass
# per kind, so callers and tests catch by class and never by message:
#
#   zulake_error_argument              an argument of the wrong type or value
#   zulake_error_uri                   a URI or a path in the log that zulake
#                                      will not open
#   zulake_error_storage               a file the storage backend cannot read;
#                                      from Azure also `status` and `code`
#   zulake_error_auth                  Azure refused the credentials (HTTP
#                                      401 twice, or 403), or credentials()
#                                      failed; `status`, `code`. Never the
#                                      token (D4)
#   zulake_error_not_table             no Delta log at the location
#   zulake_error_version               a version or timestamp the log lacks
#   zulake_error_corrupt_log           a log that breaks the protocol
#   zulake_error_checkpoint_unreadable a version that needs a checkpoint
#                                      zulake cannot read or that is not
#                                      whole, commit 0 being gone;
#                                      `checkpoint`, `parent`
#   zulake_error_unsupported_feature   a reader feature zulake refuses (D7);
#                                      the condition's `feature` field
#                                      names it, `protocol` holds the
#                                      lake_protocol() frame
#   zulake_error_int64                 a 64-bit value a double cannot hold
#                                      exactly (D10); `value` is its digits
#   zulake_error_filter                a filter outside the pruning subset,
#                                      or a value it cannot compare
#   zulake_error_column_unreadable     a column named in `columns` or used
#                                      in `filter` that qio cannot return
#                                      (design section 7); `column`,
#                                      `reason`
#   zulake_error_missing_package       a suggested package the call needs
#                                      is not installed (zuroar, for the
#                                      rows of deletion vectors); `package`
#
# and three warnings, each with parent class `zulake_warning`:
#
#   zulake_warning_count_unknown       lake_count() met a file without
#                                      `numRecords`; `files` counts them
#   zulake_warning_int64               a `long` statistic the `int64` mode
#                                      cannot hold, shown as NA; `value`,
#                                      `column`, `path`
#   zulake_warning_column_skipped      a column qio cannot return, left out
#                                      of a read; `column`, `reason`
#
# Base R only: the package has no rlang or cli dependency.

zulake_abort <- function(class, message, ..., call = NULL) {
  cnd <- structure(
    class = c(paste0("zulake_error_", class), "zulake_error", "error", "condition"),
    list(message = message, call = call, ...)
  )
  stop(cnd)
}

zulake_warn <- function(class, message, ...) {
  cnd <- structure(
    class = c(paste0("zulake_warning_", class), "zulake_warning", "warning", "condition"),
    list(message = message, call = NULL, ...)
  )
  warning(cnd)
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

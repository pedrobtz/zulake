# Commit timestamps and time travel by timestamp (design section 4.2; the
# protocol's "In-Commit Timestamps").

# Whether the table records in-commit timestamps, and from which version.
ict_info <- function(protocol, metadata) {
  conf <- metadata[["configuration"]]
  writer <- as.character(protocol[["writerFeatures"]])
  on <- protocol[["minWriterVersion"]] >= 7 && "inCommitTimestamp" %in% writer &&
    identical(conf[["delta.enableInCommitTimestamps"]], "true")
  if (!on) {
    return(list(enabled = FALSE))
  }
  from <- conf[["delta.inCommitTimestampEnablementVersion"]]
  if (is.null(from)) {
    return(list(enabled = TRUE, version = 0))
  }
  if (!grepl("^[0-9]+$", from)) {
    zulake_abort("corrupt_log", "the table's in-commit timestamp enablement version is not a whole number.")
  }
  list(enabled = TRUE, version = as.numeric(from))
}

# A commit file's timestamp in milliseconds since the epoch: its
# `commitInfo.inCommitTimestamp` when the table records them from that
# version on, otherwise the file's modification time, as the protocol says.
commit_time_ms <- function(entry, ict, read) {
  if (ict$enabled && entry$version >= ict$version) {
    actions <- read(entry$name)
    info <- if (length(actions)) actions[[1L]][["commitInfo"]] else NULL
    ts <- if (is.list(info)) info[["inCommitTimestamp"]] else NULL
    if (!is_whole(ts)) {
      zulake_abort(
        "corrupt_log",
        sprintf(
          "commit %s has no `inCommitTimestamp` in a first `commitInfo` action, which the table's in-commit timestamps require.",
          format_number(entry$version)
        ),
        version = entry$version
      )
    }
    return(as.numeric(ts))
  }
  mtime_ms(entry$modification_time)
}

# Milliseconds, truncated as Delta readers truncate file times, after
# rounding to the microsecond so a time set to a whole millisecond stays it.
mtime_ms <- function(x) {
  floor(round(as.numeric(x) * 1e6) / 1000)
}

ms_to_posixct <- function(ms) {
  as.POSIXct(ms / 1000, origin = "1970-01-01", tz = "UTC")
}

# The version a timestamp selects: the latest commit at or before it, each
# commit timed as commit_time_ms() says; a timestamp before every commit
# selects the first version, as deltalake 1.7.0 does.
#
# With in-commit timestamps enabled part-way, the protocol's recommendation
# considers only the versions on the timestamp's side of the enablement.
# Taking the latest version at or before the timestamp already does that:
# a timestamp at or after the enablement timestamp is reached by the
# enablement version itself, and one before it by no later version, since
# in-commit timestamps start there and only grow.
version_at <- function(timestamp, entries, protocol, metadata, read) {
  commits <- entries[entries$kind == "commit", , drop = FALSE]
  ict <- ict_info(protocol, metadata)
  t_us <- round(as.numeric(timestamp) * 1e6)
  ms <- vapply(seq_len(nrow(commits)), function(i) commit_time_ms(commits[i, , drop = FALSE], ict, read), 0)
  hit <- ms * 1000 <= t_us
  if (any(hit)) max(commits$version[hit]) else min(commits$version)
}

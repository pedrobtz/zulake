# Commit timestamps and time travel by timestamp (design section 4.2; the
# protocol's "In-Commit Timestamps").

# Whether the table records in-commit timestamps, and from which version.
ict_info <- function(protocol, metadata) {
  conf <- metadata[["configuration"]]
  writer <- as.character(protocol[["writerFeatures"]])
  on <- protocol[["minWriterVersion"]] >= 7 &&
    "inCommitTimestamp" %in% writer &&
    identical(conf[["delta.enableInCommitTimestamps"]], "true")
  if (!on) {
    return(list(enabled = FALSE))
  }
  from <- conf[["delta.inCommitTimestampEnablementVersion"]]
  if (is.null(from)) {
    return(list(enabled = TRUE, version = 0))
  }
  if (!grepl("^[0-9]+$", from)) {
    zulake_abort(
      "corrupt_log",
      "the table's in-commit timestamp enablement version is not a whole number."
    )
  }
  list(enabled = TRUE, version = as.numeric(from))
}

# The timestamps of `commits` (rows of the listing, in version order) in
# milliseconds since the epoch, for the rows `rows`: a commit's
# `commitInfo.inCommitTimestamp` when the table records them from that
# version on, otherwise its file's modification time, as the protocol says.
# File times are made increasing first, as Delta's history and deltalake
# 1.7.0 make them: a commit whose time is not after the previous one's
# counts as 1 ms after it (#52). In-commit timestamps only grow, and start
# where file times end, so they need no such step.
commit_times_ms <- function(commits, ict, read, rows = seq_len(nrow(commits))) {
  ms <- mtime_ms(commits$modification_time)
  for (i in seq_along(ms)[-1L]) {
    if (ms[i] <= ms[i - 1L]) {
      ms[i] <- ms[i - 1L] + 1
    }
  }
  out <- ms[rows]
  in_commit <- ict$enabled & commits$version[rows] >= ict$version
  out[in_commit] <- vapply(
    rows[in_commit],
    function(i) in_commit_time_ms(commits[i, , drop = FALSE], read),
    0
  )
  out
}

in_commit_time_ms <- function(entry, read) {
  actions <- read(entry$name)
  info <- if (length(actions)) actions[[1L]][["commitInfo"]] else NULL
  ts <- if (is.list(info)) info[["inCommitTimestamp"]] else NULL
  if (!is_whole(ts)) {
    zulake_abort(
      "corrupt_log",
      sprintf(
        paste(
          "commit %s has no `inCommitTimestamp` in a first `commitInfo` action,",
          "which the table's in-commit timestamps require."
        ),
        format_number(entry$version)
      ),
      version = entry$version
    )
  }
  as.numeric(ts)
}

# The commit entries of a listing, in version order.
listing_commits <- function(entries) {
  commits <- entries[entries$kind == "commit", , drop = FALSE]
  commits[order(commits$version), , drop = FALSE]
}

# Milliseconds, truncated as Delta readers truncate file times, after
# rounding to 10 microseconds. R reads file times exactly only to about
# 1 us on Windows (file.info() computes ticks / 1e7 - 11644473600 in a
# double), so a whole-millisecond time can arrive just below it; the
# rounding keeps it in its millisecond. A time within 5 us below a
# millisecond boundary counts as the next millisecond.
mtime_ms <- function(x) {
  floor(round(as.numeric(x) * 1e5) / 100)
}

ms_to_posixct <- function(ms) {
  as.POSIXct(ms / 1000, origin = "1970-01-01", tz = "UTC")
}

# The version a timestamp selects: the latest commit at or before it, each
# commit timed as commit_times_ms() says; a timestamp before every commit
# selects the first version, as deltalake 1.7.0 does.
#
# With in-commit timestamps enabled part-way, the protocol's recommendation
# considers only the versions on the timestamp's side of the enablement.
# Taking the latest version at or before the timestamp already does that:
# a timestamp at or after the enablement timestamp is reached by the
# enablement version itself, and one before it by no later version, since
# in-commit timestamps start there and only grow.
version_at <- function(timestamp, entries, protocol, metadata, read) {
  commits <- listing_commits(entries)
  if (!nrow(commits)) {
    # A log of checkpoints alone keeps no commit time (#51).
    zulake_abort(
      "version",
      paste(
        "the log holds no commit file, so it keeps no commit times to travel",
        "by: open a `version` instead."
      )
    )
  }
  ict <- ict_info(protocol, metadata)
  t_us <- round(as.numeric(timestamp) * 1e6)
  ms <- commit_times_ms(commits, ict, read)
  hit <- ms * 1000 <= t_us
  if (any(hit)) max(commits$version[hit]) else min(commits$version)
}

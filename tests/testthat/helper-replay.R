# Helpers for the log replay tests (test-replay.R, test-hostile.R,
# test-protocol.R). Here, not in a test file, because the suite shuffles
# every top-level expression of a test file.

# Sets each commit file's modification time to its own
# commitInfo.timestamp, as tools/oracle/answers.py does before asking
# deltalake, since git keeps no modification times.
set_commit_mtimes <- function(path) {
  log <- file.path(path, "_delta_log")
  for (name in list.files(log, pattern = "^[0-9]{20}[.]json$")) {
    f <- file.path(log, name)
    for (a in zujson::json_parse_ndjson(readBin(f, "raw", file.size(f)))) {
      ts <- a[["commitInfo"]][["timestamp"]]
      if (!is.null(ts)) {
        # Half a millisecond on: R's Sys.setFileTime() on Windows truncates
        # the fraction to whole milliseconds, so ts itself can be stored
        # 1 ms low. Readers truncate to milliseconds, so this reads as ts.
        stopifnot(Sys.setFileTime(f, as.POSIXct((ts + 0.5) / 1000, origin = "1970-01-01", tz = "UTC")))
        got <- mtime_ms(file.mtime(f))
        if (got != ts) {
          stop(sprintf("cannot set %s to %.0f ms: it reads back as %.0f ms", f, ts, got), call. = FALSE)
        }
        break
      }
    }
  }
  invisible(path)
}

# Commit file modification times in milliseconds, by version.
commit_mtimes_ms <- function(path) {
  log <- file.path(path, "_delta_log")
  names <- list.files(log, pattern = "^[0-9]{20}[.]json$")
  stats::setNames(
    mtime_ms(file.mtime(file.path(log, names))),
    as.numeric(substr(names, 1L, 20L))
  )
}

# "2025-08-09T14:43:13.561Z", as the answers write a time, as POSIXct.
answer_time <- function(at) {
  stopifnot(grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3}Z$", at))
  day <- as.numeric(as.Date(substr(at, 1L, 10L)))
  secs <- as.numeric(substr(at, 12L, 13L)) * 3600 + as.numeric(substr(at, 15L, 16L)) * 60 +
    as.numeric(substr(at, 18L, 19L))
  ms <- as.numeric(substr(at, 21L, 23L))
  as.POSIXct(((day * 86400 + secs) * 1000 + ms) / 1000, origin = "1970-01-01", tz = "UTC")
}

# A snapshot's live files in the shape of deltalake's add_actions answer,
# for the columns replay decides: path, size, modification time and the
# deletion vector descriptor (when the answer has one).
replay_files_frame <- function(tbl, answer_columns) {
  a <- tbl$files$action
  out <- list(
    path = tbl$files$path,
    size_bytes = vapply(a, function(x) x[["size"]], 0),
    modification_time = vapply(a, function(x) x[["modificationTime"]], 0)
  )
  if ("deletion_vector" %in% answer_columns) {
    out$deletion_vector <- lapply(a, function(x) {
      dv <- x[["deletionVector"]]
      if (is.null(dv)) {
        return(NULL)
      }
      list(
        storageType = dv[["storageType"]], pathOrInlineDv = dv[["pathOrInlineDv"]],
        offset = dv[["offset"]], sizeInBytes = dv[["sizeInBytes"]], cardinality = dv[["cardinality"]]
      )
    })
  }
  cols <- lapply(out, function(col) if (is.list(col)) I(col) else col)
  structure(cols, class = "data.frame", row.names = seq_along(out$path))
}

# A storage backend that records every path it is asked for, in
# `env$calls` (one "<operation> <path>" string per call).
recording_storage <- function(storage, env) {
  env$calls <- character()
  record <- function(op, path) env$calls <- c(env$calls, paste(op, path))
  wrapped <- storage
  wrapped$list <- function(prefix, after = NULL) {
    record("list", prefix)
    storage$list(prefix, after)
  }
  wrapped$get <- function(path) {
    record("get", path)
    storage$get(path)
  }
  wrapped$get_range <- function(path, from, to) {
    record("get_range", path)
    storage$get_range(path, from, to)
  }
  wrapped$head <- function(path) {
    record("head", path)
    storage$head(path)
  }
  if (is.function(storage$local_path)) {
    wrapped$local_path <- function(path) {
      record("local_path", path)
      storage$local_path(path)
    }
  }
  wrapped
}

# The log files a snapshot of `path` at `version` reads, by name (the
# `_delta_log/` prefix dropped), in the order it reads them.
log_reads <- function(path, version = NULL) {
  rec <- new.env()
  storage <- recording_storage(zulake:::storage_local(path), rec)
  zulake:::snapshot_build(storage, path, version)
  calls <- rec$calls[!startsWith(rec$calls, "list ")]
  sub("^[a-z_]+ _delta_log/", "", calls)
}

# ---- checkpoints -----------------------------------------------------------

# Names of the fixture tables with a checkpoint.
checkpoint_tables <- function() {
  has <- vapply(fixture_names("tables"), function(t) {
    any(grepl("[.]checkpoint[.]", list.files(file.path(fixture_table(t), "_delta_log"))))
  }, NA)
  names(has)[has]
}

# A private copy of fixture table `name` with its checkpoints, sidecars and
# _last_checkpoint deleted, so that it replays from commit 0.
local_commits_only <- function(name, env = parent.frame()) {
  path <- local_fixture_copy(name, env = env)
  log <- file.path(path, "_delta_log")
  unlink(list.files(log, pattern = "[.]checkpoint[.]|^_last_checkpoint$", full.names = TRUE, all.files = TRUE))
  unlink(file.path(log, "_sidecars"), recursive = TRUE)
  path
}

# Versions of a table that have a whole checkpoint, ascending.
checkpoint_versions <- function(path) {
  entries <- zulake:::log_entries(zulake:::storage_local(path)$list("_delta_log/"))
  sort(vapply(zulake:::checkpoint_sets(entries), function(s) s$version[1L], 0))
}

# An action as the checkpoint and the commit that wrote it both say it, for
# comparing replays: null fields and empty maps left out, `dataChange`
# dropped (checkpoint writers write false, design section 4.2), names in
# byte order.
action_core <- function(x) {
  if (!is.list(x)) {
    return(x)
  }
  empty <- vapply(x, function(v) is.null(v) || (is.list(v) && !length(v)), NA)
  x <- x[!empty]
  if (!is.null(names(x))) {
    x <- x[setdiff(names(x), "dataChange")]
    x <- x[order(names(x), method = "radix")]
  }
  lapply(x, action_core)
}

# Two snapshots of one table hold the same state, as every inspection
# function shows it: the same files (statistics, partitions, deletion
# vectors and the core of each add), protocol, metadata, schema, properties,
# transactions, domains and tombstones.
expect_same_state <- function(a, b, label) {
  expect_identical(lake_version(a), lake_version(b), label = label)
  fa <- lake_files(a)
  fb <- lake_files(b)
  cols <- setdiff(names(fa), c("uri", "data_change", "action"))
  expect_identical(fa[cols], fb[cols], label = paste(label, "lake_files()"))
  expect_identical(lapply(fa$action, action_core), lapply(fb$action, action_core), label = paste(label, "actions"))
  expect_identical(lake_partitions(a), lake_partitions(b), label = label)
  expect_identical(lake_protocol(a), lake_protocol(b), label = label)
  expect_identical(lake_metadata(a), lake_metadata(b), label = label)
  expect_identical(lake_schema(a), lake_schema(b), label = label)
  expect_identical(lake_properties(a), lake_properties(b), label = label)
  expect_identical(lake_transactions(a), lake_transactions(b), label = label)
  expect_identical(lake_domains(a), lake_domains(b), label = label)
  ra <- lake_removed(a)
  rb <- lake_removed(b)
  expect_identical(ra[c("path", "deletion_timestamp", "size_bytes")], rb[c("path", "deletion_timestamp", "size_bytes")], label = label)
  sa <- lake_summary(a)
  sb <- lake_summary(b)
  expect_identical(sa[names(sa) != "timestamp"], sb[names(sb) != "timestamp"], label = label)
}

# A V2 checkpoint in JSON (a UUID-named file, one action per line) at
# `version` of the table at `path`.
write_json_checkpoint <- function(path, version, lines, uuid = "3a0d65cd-4b4c-4b4b-8a0b-0f2a1c2b3d4e") {
  f <- file.path(path, "_delta_log", sprintf("%020.0f.checkpoint.%s.json", version, uuid))
  writeBin(charToRaw(paste0(paste(lines, collapse = "\n"), "\n")), f)
  invisible(f)
}

# ---- hand-written logs ---------------------------------------------------

json_line <- function(x) zujson::json_write(x, auto_unbox = TRUE)

protocol_line <- function(reader = 1L, writer = 2L, reader_features = NULL, writer_features = NULL) {
  p <- list(minReaderVersion = reader, minWriterVersion = writer)
  if (!is.null(reader_features)) p$readerFeatures <- I(reader_features)
  if (!is.null(writer_features)) p$writerFeatures <- I(writer_features)
  json_line(list(protocol = p))
}

# `columns` is a named character vector of Delta types; `physical` gives
# column mapping physical names for some of them.
metadata_line <- function(columns = c(id = "long"), partition = character(),
                          configuration = list(), physical = character()) {
  fields <- lapply(names(columns), function(nm) {
    md <- structure(list(), names = character())
    if (nm %in% names(physical)) md <- list(delta.columnMapping.physicalName = physical[[nm]])
    list(name = nm, type = columns[[nm]], nullable = TRUE, metadata = md)
  })
  schema <- json_line(list(type = "struct", fields = fields))
  conf <- if (length(configuration)) configuration else structure(list(), names = character())
  json_line(list(metaData = list(
    id = "hand-written", format = list(provider = "parquet", options = structure(list(), names = character())),
    schemaString = schema, partitionColumns = I(partition), configuration = conf
  )))
}

add_line <- function(path, partition = list(), size = 100, dv = NULL) {
  pv <- if (length(partition)) partition else structure(list(), names = character())
  a <- list(path = path, partitionValues = pv, size = size, modificationTime = 0, dataChange = TRUE)
  if (!is.null(dv)) a$deletionVector <- dv
  json_line(list(add = a))
}

remove_line <- function(path, dv = NULL) {
  r <- list(path = path, deletionTimestamp = 0, dataChange = TRUE)
  if (!is.null(dv)) r$deletionVector <- dv
  json_line(list(remove = r))
}

# Writes commit `version` of the table at `path`, one action per line.
write_commit <- function(path, version, lines) {
  dir <- file.path(path, "_delta_log")
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  f <- file.path(dir, sprintf("%020.0f.json", version))
  con <- file(f, "wb")
  on.exit(close(con))
  writeBin(charToRaw(paste0(paste(lines, collapse = "\n"), "\n")), con)
  invisible(f)
}

# A table in a temporary directory, removed when `env` ends, whose commit 0
# holds `lines` (by default a protocol, metadata and one file).
hand_table <- function(lines = NULL, env = parent.frame()) {
  path <- file.path(withr::local_tempdir(.local_envir = env), "table")
  if (is.null(lines)) {
    lines <- c(protocol_line(), metadata_line(), add_line("part-0.parquet"))
  }
  write_commit(path, 0, lines)
  path
}

expect_no_snapshot <- function(expr, class) {
  tbl <- "untouched"
  expect_error(tbl <- expr, class = class)
  expect_identical(tbl, "untouched")
}

# `x` (a parsed JSON value) with one node, chosen at random, replaced by a
# value of another JSON type. For the structural corruption test.
mutate_json <- function(x) {
  replacements <- list(NULL, 1L, -1, 2^60, "x", "", TRUE, list(), structure(list(), names = character()),
                       list(a = 1L), I(c("a", "b")), I(1:2))
  paths <- list()
  walk <- function(v, path) {
    paths[[length(paths) + 1L]] <<- path
    if (is.list(v)) for (i in seq_along(v)) walk(v[[i]], c(path, i))
  }
  walk(x, integer())
  path <- paths[[sample.int(length(paths), 1L)]]
  value <- replacements[sample.int(length(replacements), 1L)]
  if (!length(path)) {
    return(value[[1L]])
  }
  last <- path[length(path)]
  if (length(path) == 1L) {
    x[last] <- value
  } else {
    parent <- x[[path[-length(path)]]]
    parent[last] <- value
    x[[path[-length(path)]]] <- parent
  }
  x
}

# A private copy of the directory `path`, removed when `env` ends.
local_copy_dir <- function(path, env = parent.frame()) {
  dest <- withr::local_tempdir(.local_envir = env)
  stopifnot(file.copy(path, dest, recursive = TRUE, copy.date = TRUE))
  file.path(dest, basename(path))
}

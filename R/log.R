# The `_delta_log/` directory: what its listing holds, and its JSON files.

log_dir <- "_delta_log/"

# Every entry of a `_delta_log/` listing the protocol names, one row each:
# `name`, `kind` ("commit", "checkpoint", "compaction", "checksum",
# "last_checkpoint"), `version` (the start version for a compaction),
# `end_version` (compactions only), `part` and `parts` (multi-part
# checkpoints only), `size` and `modification_time`. Anything else in the
# directory (hidden files, `.tmp/`, `_staged_commits/`) is not the log and is
# left out; subdirectories are not listed at all.
log_entries <- function(listing) {
  name <- listing$name
  n <- length(name)
  kind <- rep(NA_character_, n)
  digits <- "([0-9]{20})"
  patterns <- c(
    commit = paste0("^", digits, "[.]json$"),
    checkpoint = paste0("^", digits, "[.]checkpoint[.]parquet$"),
    checkpoint = paste0("^", digits, "[.]checkpoint[.][0-9]{10}[.][0-9]{10}[.]parquet$"),
    checkpoint = paste0("^", digits, "[.]checkpoint[.][0-9a-fA-F-]{36}[.](json|parquet)$"),
    compaction = paste0("^", digits, "[.]", digits, "[.]compacted[.]json$"),
    checksum = paste0("^", digits, "[.]crc$"),
    last_checkpoint = "^_last_checkpoint$"
  )
  for (i in seq_along(patterns)) {
    hit <- is.na(kind) & grepl(patterns[[i]], name)
    kind[hit] <- names(patterns)[i]
  }
  keep <- !is.na(kind)
  name <- name[keep]
  kind <- kind[keep]
  versioned <- kind != "last_checkpoint"
  version <- rep(NA_real_, length(name))
  version[versioned] <- parse_version(substr(name[versioned], 1L, 20L), name[versioned])
  end_version <- rep(NA_real_, length(name))
  compaction <- kind == "compaction"
  end_version[compaction] <- parse_version(substr(name[compaction], 22L, 41L), name[compaction])
  bad <- compaction & !(end_version > version)
  if (any(bad)) {
    zulake_abort(
      "corrupt_log",
      sprintf("log compaction file %s ends before it starts.", format_string(name[bad][1L]))
    )
  }
  multi <- kind == "checkpoint" & grepl("[.]checkpoint[.][0-9]{10}[.][0-9]{10}[.]parquet$", name)
  part <- rep(NA_real_, length(name))
  parts <- rep(NA_real_, length(name))
  part[multi] <- as.numeric(substr(name[multi], 33L, 42L))
  parts[multi] <- as.numeric(substr(name[multi], 44L, 53L))
  new_data_frame(list(
    name = name,
    kind = kind,
    version = version,
    end_version = end_version,
    part = part,
    parts = parts,
    size = listing$size[keep],
    modification_time = listing$modification_time[keep]
  ))
}

# Twenty zero-padded digits as a double, refused at 2^53 and above, where a
# double no longer holds every whole number (design section 7). Compared as
# text, so the check itself cannot round.
parse_version <- function(digits, name) {
  limit <- sprintf("%020.0f", max_exact)
  over <- sorts_after(digits, limit)
  if (any(over)) {
    zulake_abort(
      "corrupt_log",
      sprintf(
        "log file %s has a version of 2^53 or more, which zulake cannot hold exactly.",
        format_string(name[over][1L])
      )
    )
  }
  as.numeric(digits)
}

commit_name <- function(version) {
  sprintf("%020.0f.json", version)
}

# A JSON log file's actions, one named list per line. A line that is not
# JSON, or not a JSON object, is a corrupt log.
read_actions <- function(storage, name) {
  bytes <- storage$get(paste0(log_dir, name))
  marked <- mark_big_integers(bytes)
  actions <- tryCatch(
    zujson::json_parse_ndjson(marked),
    zujson_error = function(e) {
      zulake_abort(
        "corrupt_log",
        sprintf("log file %s is not valid JSON: %s", format_string(name), conditionMessage(e)),
        file = name,
        parent = e
      )
    }
  )
  if (!identical(marked, bytes)) {
    actions <- seal_marks(actions)
  }
  for (i in seq_along(actions)) {
    a <- actions[[i]]
    if (!is.list(a) || is.null(names(a)) || !length(a)) {
      zulake_abort(
        "corrupt_log",
        sprintf("line %d of log file %s is not a JSON object with an action.", i, format_string(name)),
        file = name
      )
    }
  }
  actions
}

# A log file's bytes with every integer past 2^53 - 1 rewritten as a marked
# string (int64.R), so that zujson cannot round it. Bytes with a NUL are left
# (or that are not UTF-8) as they are: they are not JSON, and zujson says so.
mark_big_integers <- function(bytes) {
  if (!length(bytes) || any(bytes == as.raw(0L))) {
    return(bytes)
  }
  text <- rawToChar(bytes)
  if (!validUTF8(text)) {
    return(bytes)
  }
  Encoding(text) <- "UTF-8"
  marked <- mark_numbers(text)
  if (identical(marked, text)) bytes else charToRaw(marked)
}

# `_delta_log/_last_checkpoint`, parsed, or NULL when the log has none. Its
# `version` is checked here; the rest of it is used when checkpoints are
# read (Stage 2b).
read_last_checkpoint <- function(storage, entries) {
  if (!any(entries$kind == "last_checkpoint")) {
    return(NULL)
  }
  name <- "_last_checkpoint"
  bytes <- storage$get(paste0(log_dir, name))
  x <- tryCatch(
    zujson::json_parse_raw(bytes),
    zujson_error = function(e) {
      zulake_abort(
        "corrupt_log",
        sprintf("_last_checkpoint is not valid JSON: %s", conditionMessage(e)),
        file = name,
        parent = e
      )
    }
  )
  if (!is.list(x) || !is_whole(x[["version"]]) || x[["version"]] < 0 || x[["version"]] > max_exact) {
    zulake_abort(
      "corrupt_log",
      "_last_checkpoint has no `version` that is a whole number from 0 to 2^53 - 1.",
      file = name
    )
  }
  x[["version"]] <- as.numeric(x[["version"]])
  x
}

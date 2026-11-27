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
    checkpoint = paste0(
      "^",
      digits,
      "[.]checkpoint[.][0-9]{10}[.][0-9]{10}[.]parquet$"
    ),
    checkpoint = paste0(
      "^",
      digits,
      "[.]checkpoint[.][0-9a-fA-F-]{36}[.](json|parquet)$"
    ),
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
  version[versioned] <- parse_version(
    substr(name[versioned], 1L, 20L),
    name[versioned]
  )
  end_version <- rep(NA_real_, length(name))
  compaction <- kind == "compaction"
  end_version[compaction] <- parse_version(
    substr(name[compaction], 22L, 41L),
    name[compaction]
  )
  # The protocol names a compaction file only for y > x: any other is not a
  # log file, and is left out like other names it does not define (#69).
  named <- !compaction | end_version > version
  name <- name[named]
  kind <- kind[named]
  version <- version[named]
  end_version <- end_version[named]
  keep[keep] <- named
  multi <- kind == "checkpoint" &
    grepl("[.]checkpoint[.][0-9]{10}[.][0-9]{10}[.]parquet$", name)
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

# The size `entries` (log_entries()) gives the log file `name`, NA when it
# lists no such file.
listed_size <- function(entries, name) {
  entries$size[match(name, entries$name)]
}

# The bytes of the log file at `path` (relative to the table root), which
# must have the `size` its listing gave (NA: no size to check). A body cut
# short in transfer (a server that closes the connection without a
# Content-Length) parses as a shorter log, so its length is compared before
# anything reads it (#122).
log_get <- function(storage, path, size) {
  bytes <- storage$get(path)
  check_log_size(path, length(bytes), size)
  bytes
}

# `got` bytes read of the log file `path` against the `size` listed for it,
# or named by the action that points to it (`from`): a difference is a
# zulake_error_storage with both sizes.
check_log_size <- function(path, got, size, from = "its listing gives") {
  if (is.na(size) || got == size) {
    return(invisible())
  }
  zulake_abort(
    "storage",
    sprintf(
      "log file %s has %s bytes, but %s %s: it was cut short or changed while it was read.",
      format_string(path),
      format_number(got),
      from,
      format_number(size)
    ),
    path = path,
    size = as.numeric(got),
    listed_size = as.numeric(size)
  )
}

# A JSON log file's actions, one named list per line, from its bytes, which
# must have the `size` its listing gave. A line that is not JSON, or not a
# JSON object, is a corrupt log, and so is a line holding more than one
# action: the protocol stores every action on a line of its own (#121).
read_actions <- function(storage, name, size) {
  bytes <- log_get(storage, paste0(log_dir, name), size)
  marked <- mark_big_integers(bytes)
  actions <- tryCatch(
    zujson::json_parse_ndjson(marked),
    zujson_error = function(e) {
      zulake_abort(
        "corrupt_log",
        sprintf(
          "log file %s is not valid JSON: %s",
          format_string(name),
          conditionMessage(e)
        ),
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
        sprintf(
          "line %d of log file %s is not a JSON object with an action.",
          i,
          format_string(name)
        ),
        file = name
      )
    }
    key <- repeated_key(a)
    if (!is.null(key)) {
      line <- file_line(bytes, i)
      zulake_abort(
        "corrupt_log",
        sprintf(
          "line %d of log file %s has an object with the key %s twice.",
          line,
          format_string(name),
          format_string(key)
        ),
        file = name,
        line = line,
        key = key
      )
    }
    if (length(a) > 1L) {
      line <- file_line(bytes, i)
      zulake_abort(
        "corrupt_log",
        sprintf(
          "line %d of log file %s holds the actions %s, where the protocol stores one action per line.",
          line,
          format_string(name),
          paste(format_string(names(a)), collapse = " and ")
        ),
        file = name,
        line = line
      )
    }
  }
  actions
}

# The first key that a parsed JSON value holds twice in one object, at any
# depth, or NULL. zujson keeps every member of an object, under its name
# once unescaped, so a repeated key is a repeated name here (#102).
repeated_key <- function(x) {
  nm <- names(x)
  if (!is.null(nm)) {
    d <- anyDuplicated(nm)
    if (d) {
      return(nm[d])
    }
  }
  for (v in x) {
    if (is.list(v)) {
      key <- repeated_key(v)
      if (!is.null(key)) {
        return(key)
      }
    }
  }
  NULL
}

# The line of a JSON log file that holds its `i`-th record: zujson skips
# blank lines (nothing but spaces, tabs and CRs) and a byte order mark that
# starts the file, so the two can differ.
file_line <- function(bytes, i) {
  bom <- as.raw(c(0xef, 0xbb, 0xbf))
  if (length(bytes) >= 3L && identical(bytes[1:3], bom)) {
    bytes <- bytes[-(1:3)]
  }
  lines <- strsplit(rawToChar(bytes), "\n", fixed = TRUE, useBytes = TRUE)[[1L]]
  which(!grepl("^[ \t\r]*$", lines, useBytes = TRUE))[i]
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

# `_delta_log/_last_checkpoint`, parsed, or NULL when the log has none. Only
# its `version` is read, and checked here; replay finds checkpoints in the
# listing (design section 4.2), and the other fields are kept as parsed.
read_last_checkpoint <- function(storage, entries) {
  if (!any(entries$kind == "last_checkpoint")) {
    return(NULL)
  }
  name <- "_last_checkpoint"
  bytes <- log_get(storage, paste0(log_dir, name), listed_size(entries, name))
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
  key <- repeated_key(x)
  if (!is.null(key)) {
    # The protocol calls such a _last_checkpoint invalid.
    zulake_abort(
      "corrupt_log",
      sprintf(
        "_last_checkpoint has an object with the key %s twice.",
        format_string(key)
      ),
      file = name,
      key = key
    )
  }
  if (
    !is.list(x) ||
      !is_whole(x[["version"]]) ||
      x[["version"]] < 0 ||
      x[["version"]] > max_exact
  ) {
    zulake_abort(
      "corrupt_log",
      "_last_checkpoint has no `version` that is a whole number from 0 to 2^53 - 1.",
      file = name
    )
  }
  x[["version"]] <- as.numeric(x[["version"]])
  x
}

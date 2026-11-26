# Log replay (design section 4.2; the protocol's "Action Reconciliation").
#
# Until qio reads nested Parquet (D14), replay starts at commit 0 and reads
# JSON only: commits, and log compaction files in place of the commits they
# cover. Checkpoints are listed but never read; a log that no longer reaches
# commit 0 is refused with `zulake_error_checkpoint_unreadable`.

# The files to read, in order, to reach `version`: one row per file, `name`,
# `from` and `to` (the versions it covers). Greedy from commit 0: at each
# version, the compaction file that starts there and reaches furthest
# without passing `version`, else the commit itself.
replay_plan <- function(entries, version) {
  commits <- entries[entries$kind == "commit", , drop = FALSE]
  compactions <- entries[entries$kind == "compaction" & entries$end_version <= version, , drop = FALSE]
  names <- character()
  from <- numeric()
  to <- numeric()
  at <- 0
  while (at <= version) {
    hit <- which(compactions$version == at)
    if (length(hit)) {
      best <- hit[which.max(compactions$end_version[hit])]
      names <- c(names, compactions$name[best])
      from <- c(from, at)
      to <- c(to, compactions$end_version[best])
      at <- compactions$end_version[best] + 1
      next
    }
    hit <- match(at, commits$version)
    if (is.na(hit)) {
      missing_commit(entries, at, version)
    }
    names <- c(names, commits$name[hit])
    from <- c(from, at)
    to <- c(to, at)
    at <- at + 1
  }
  new_data_frame(list(name = names, from = from, to = to))
}

missing_commit <- function(entries, at, version) {
  checkpoints <- entries$version[entries$kind == "checkpoint" & entries$version >= at & entries$version <= version]
  if (length(checkpoints)) {
    cp <- max(checkpoints)
    zulake_abort(
      "checkpoint_unreadable",
      sprintf(
        paste(
          "Version %s needs the checkpoint at version %s: commit %s is no longer in the log.",
          "zulake cannot read checkpoints yet (it waits for a qio that reads nested Parquet)."
        ),
        format_number(version), format_number(cp), format_number(at)
      ),
      version = version,
      checkpoint = cp
    )
  }
  zulake_abort(
    "corrupt_log",
    sprintf(
      "commit %s (%s) is missing from the log, and no checkpoint covers it.",
      format_number(at), commit_name(at)
    ),
    version = at
  )
}

# The table's state after applying `plan`'s files in order: protocol,
# metadata, live files, tombstones, transactions and domains. `read` returns
# a file's actions by name.
replay <- function(plan, read) {
  st <- new.env(parent = emptyenv())
  st$protocol <- NULL
  st$metadata <- NULL
  st$adds <- new.env(parent = emptyenv())
  st$removes <- new.env(parent = emptyenv())
  st$txns <- list()
  st$domains <- list()
  for (i in seq_len(nrow(plan))) {
    apply_file(st, plan$name[i], read(plan$name[i]))
  }
  if (is.null(st$protocol)) {
    zulake_abort("corrupt_log", "the log has no `protocol` action.")
  }
  if (is.null(st$metadata)) {
    zulake_abort("corrupt_log", "the log has no `metaData` action.")
  }
  st
}

# One commit (or compaction) file. File actions are applied removes first,
# then adds, so a file the same commit removes and re-adds (a new deletion
# vector, new statistics) is live afterwards: actions inside one commit have
# no order, and an add and a remove of one logical file in the same commit
# means "replaced".
apply_file <- function(st, name, actions) {
  adds <- list()
  removes <- list()
  seen_protocol <- FALSE
  seen_metadata <- FALSE
  for (a in actions) {
    if (!is.null(a[["add"]])) {
      adds[[length(adds) + 1L]] <- check_add(a[["add"]], name)
    }
    if (!is.null(a[["remove"]])) {
      removes[[length(removes) + 1L]] <- check_remove(a[["remove"]], name)
    }
    if (!is.null(a[["protocol"]])) {
      if (seen_protocol) {
        zulake_abort("corrupt_log", sprintf("log file %s has two `protocol` actions.", format_string(name)))
      }
      seen_protocol <- TRUE
      st$protocol <- check_protocol(a[["protocol"]], name)
    }
    if (!is.null(a[["metaData"]])) {
      if (seen_metadata) {
        zulake_abort("corrupt_log", sprintf("log file %s has two `metaData` actions.", format_string(name)))
      }
      seen_metadata <- TRUE
      st$metadata <- check_metadata(a[["metaData"]], name)
    }
    if (!is.null(a[["txn"]])) {
      txn <- check_txn(a[["txn"]], name)
      st$txns[[txn[["appId"]]]] <- txn
    }
    if (!is.null(a[["domainMetadata"]])) {
      dm <- check_domain(a[["domainMetadata"]], name)
      if (isTRUE(dm[["removed"]])) {
        st$domains[[dm[["domain"]]]] <- NULL
      } else {
        st$domains[[dm[["domain"]]]] <- dm
      }
    }
  }
  for (r in removes) {
    key <- file_key(r)
    if (exists(key, envir = st$adds, inherits = FALSE)) {
      rm(list = key, envir = st$adds)
    }
    assign(key, r, envir = st$removes)
  }
  for (a in adds) {
    key <- file_key(a)
    if (exists(key, envir = st$removes, inherits = FALSE)) {
      rm(list = key, envir = st$removes)
    }
    assign(key, a, envir = st$adds)
  }
  invisible(st)
}

# The protocol's key for a logical file: `(path, deletionVector.uniqueId)`.
file_key <- function(action) {
  paste0(action[["path"]], "\x1f", dv_unique_id(action[["deletionVector"]]))
}

# `deletionVector.uniqueId`: storage type and path or inline vector, then
# `@offset` when there is an offset; "" for no deletion vector.
dv_unique_id <- function(dv) {
  if (is.null(dv)) {
    return("")
  }
  id <- paste0(dv[["storageType"]], dv[["pathOrInlineDv"]])
  if (!is.null(dv[["offset"]])) {
    id <- paste0(id, "@", int_text(dv[["offset"]]))
  }
  id
}

# ---- action checks -------------------------------------------------------
#
# The fields the protocol marks required, and the types replay relies on.
# Unknown fields and unknown actions are ignored, as the protocol requires.

bad_action <- function(name, action, problem) {
  zulake_abort(
    "corrupt_log",
    sprintf("log file %s has a `%s` action %s.", format_string(name), action, problem),
    file = name,
    action = action
  )
}

check_add <- function(x, name) {
  if (!is.list(x) || !is_string(x[["path"]]) || !nzchar(x[["path"]])) {
    bad_action(name, "add", "without a `path`")
  }
  if (!is_whole_or_marked(x[["size"]]) || is_negative(x[["size"]])) {
    bad_action(name, "add", sprintf("for %s without a valid `size`", format_string(x[["path"]])))
  }
  if (!is.null(x[["partitionValues"]]) && !is_value_map(x[["partitionValues"]])) {
    bad_action(name, "add", sprintf("for %s whose `partitionValues` is not a map of strings", format_string(x[["path"]])))
  }
  check_dv(x[["deletionVector"]], name, "add", x[["path"]])
  x
}

check_remove <- function(x, name) {
  if (!is.list(x) || !is_string(x[["path"]]) || !nzchar(x[["path"]])) {
    bad_action(name, "remove", "without a `path`")
  }
  check_dv(x[["deletionVector"]], name, "remove", x[["path"]])
  x
}

check_dv <- function(dv, name, action, path) {
  if (is.null(dv)) {
    return(invisible())
  }
  ok <- is.list(dv) && is_string(dv[["storageType"]]) && dv[["storageType"]] %in% c("u", "i", "p") &&
    is_string(dv[["pathOrInlineDv"]]) && (is.null(dv[["offset"]]) || is_whole_or_marked(dv[["offset"]]))
  if (!ok) {
    bad_action(name, action, sprintf("for %s with a malformed `deletionVector`", format_string(path)))
  }
  invisible()
}

# A JSON object whose values are strings or null.
is_value_map <- function(x) {
  is.list(x) && (!length(x) || !is.null(names(x))) &&
    all(vapply(x, function(v) is.null(v) || is_string(v), logical(1L)))
}

check_protocol <- function(x, name) {
  if (!is.list(x) || !is_whole(x[["minReaderVersion"]]) || !is_whole(x[["minWriterVersion"]])) {
    bad_action(name, "protocol", "without whole-number `minReaderVersion` and `minWriterVersion`")
  }
  for (field in c("readerFeatures", "writerFeatures")) {
    f <- x[[field]]
    if (!is.null(f) && !(is.character(f) && !anyNA(f)) && !(is.logical(f) && !length(f))) {
      bad_action(name, "protocol", sprintf("whose `%s` is not an array of strings", field))
    }
  }
  x
}

check_metadata <- function(x, name) {
  if (!is.list(x) || !is_string(x[["id"]]) || !is_string(x[["schemaString"]])) {
    bad_action(name, "metaData", "without an `id` and a `schemaString`")
  }
  pc <- x[["partitionColumns"]]
  if (!(is.character(pc) && !anyNA(pc)) && !(is.logical(pc) && !length(pc))) {
    bad_action(name, "metaData", "whose `partitionColumns` is not an array of strings")
  }
  x[["partitionColumns"]] <- as.character(pc)
  if (!is.null(x[["configuration"]]) && !is_value_map(x[["configuration"]])) {
    bad_action(name, "metaData", "whose `configuration` is not a map of strings")
  }
  x[["schema"]] <- tryCatch(
    zujson::json_parse(x[["schemaString"]]),
    zujson_error = function(e) bad_action(name, "metaData", "whose `schemaString` is not valid JSON")
  )
  fields <- if (is.list(x[["schema"]])) x[["schema"]][["fields"]]
  if (!is.list(x[["schema"]]) || !identical(x[["schema"]][["type"]], "struct") ||
    !(is.list(fields) || (is.logical(fields) && !length(fields)))) {
    bad_action(name, "metaData", "whose `schemaString` is not a struct")
  }
  x[["schema"]][["fields"]] <- as.list(fields)
  x
}

check_txn <- function(x, name) {
  if (!is.list(x) || !is_string(x[["appId"]]) || !nzchar(x[["appId"]]) || !is_whole_or_marked(x[["version"]])) {
    bad_action(name, "txn", "without an `appId` and a whole-number `version`")
  }
  x
}

check_domain <- function(x, name) {
  if (!is.list(x) || !is_string(x[["domain"]]) || !nzchar(x[["domain"]]) || !is_string(x[["configuration"]]) ||
    !(is.logical(x[["removed"]]) && length(x[["removed"]]) == 1L && !is.na(x[["removed"]]))) {
    bad_action(name, "domainMetadata", "without a `domain`, a `configuration` and `removed`")
  }
  x
}

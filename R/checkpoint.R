# Checkpoints (design section 4.2, D14): classic, multi-part and V2, with
# V2's sidecars, read through qio and turned into the actions a JSON commit
# holding the same actions would parse to, so that replay, the inspection
# functions and the reader-feature gate see one representation whichever
# way the state was built.

# The checkpoints of a listing that are whole, latest version first: a list
# of entry frames, each holding one checkpoint's files (a multi-part
# checkpoint's parts in part order). At one version a classic checkpoint
# comes first, then V2 checkpoints by name, then multi-part sets by their
# number of parts. A multi-part set with a part missing is not whole, and
# is left out.
checkpoint_sets <- function(entries) {
  cp <- entries[entries$kind == "checkpoint", , drop = FALSE]
  out <- list()
  for (v in sort(unique(cp$version), decreasing = TRUE)) {
    at <- cp[cp$version == v, , drop = FALSE]
    single <- at[is.na(at$parts), , drop = FALSE]
    classic <- endsWith(single$name, ".checkpoint.parquet")
    single <- single[
      order(!classic, single$name, method = "radix"),
      ,
      drop = FALSE
    ]
    for (i in seq_len(nrow(single))) {
      out[[length(out) + 1L]] <- single[i, , drop = FALSE]
    }
    multi <- at[!is.na(at$parts), , drop = FALSE]
    for (n in sort(unique(multi$parts))) {
      set <- multi[multi$parts == n, , drop = FALSE]
      if (nrow(set) == n && setequal(set$part, seq_len(n))) {
        out[[length(out) + 1L]] <- set[order(set$part), , drop = FALSE]
      }
    }
  }
  out
}

# Versions that have a checkpoint file but no whole checkpoint.
incomplete_checkpoints <- function(entries, sets) {
  versions <- unique(entries$version[entries$kind == "checkpoint"])
  whole <- vapply(sets, function(s) s$version[1L], 0)
  setdiff(versions, whole)
}

# The actions of one checkpoint (`set`, from checkpoint_sets()): every part,
# and the sidecars a V2 checkpoint names, in that order. A read failure (a
# zulake_error, such as a file that is gone, an error of qio's, or one of
# this file's refusals: a shape no action has, an integer past 2^53 without
# bit64) is a `zulake_error_checkpoint_unreadable`, which replay answers by
# trying an earlier checkpoint or the commits; an authentication failure is
# not, since no other file would fare better. Any other error, such as a
# bug in this code, propagates as it is (#89).
read_checkpoint <- function(storage, set, read) {
  version <- set$version[1L]
  unreadable <- function(e) checkpoint_unreadable(e, version, set$name[1L])
  tryCatch(
    {
      actions <- list()
      for (name in set$name) {
        part <- if (endsWith(name, ".json")) {
          read(name)
        } else {
          log_parquet_actions(storage, paste0(log_dir, name))
        }
        actions <- c(actions, part)
      }
      sidecars <- list()
      for (a in actions) {
        if (!is.null(a[["sidecar"]])) {
          sidecars[[length(sidecars) + 1L]] <- a[["sidecar"]]
        }
      }
      for (s in sidecars) {
        actions <- c(actions, sidecar_actions(storage, s, set$name[1L]))
      }
      actions
    },
    # One handler for zulake_error: tryCatch() nests its handlers, so an
    # auth error re-raised from a handler of its own would reach this one.
    zulake_error = function(e) {
      if (inherits(e, "zulake_error_auth")) stop(e) else unreadable(e)
    },
    zulake_checkpoint_refusal = function(e) unreadable(e)
  )
}

# A read failure as the zulake_error_checkpoint_unreadable read_checkpoint()
# raises, inside it.
checkpoint_unreadable <- function(e, version, name) {
  zulake_abort(
    "checkpoint_unreadable",
    sprintf(
      "the checkpoint at version %s (%s) cannot be read: %s",
      format_number(version),
      format_string(name),
      conditionMessage(e)
    ),
    checkpoint = version,
    file = name,
    parent = e
  )
}

# A refusal of this file's own, of class zulake_checkpoint_refusal (internal:
# read_checkpoint() turns it into a zulake_error_checkpoint_unreadable).
checkpoint_refusal <- function(message, parent = NULL) {
  stop(structure(
    class = c("zulake_checkpoint_refusal", "error", "condition"),
    list(message = message, call = NULL, parent = parent)
  ))
}

# `expr`, a qio call, with qio's (unclassed) errors classed as read failures.
qio_read <- function(expr) {
  tryCatch(expr, error = function(e) {
    if (inherits(e, c("zulake_error", "zulake_checkpoint_refusal"))) {
      stop(e)
    }
    checkpoint_refusal(conditionMessage(e), parent = e)
  })
}

# A V2 sidecar's add and remove actions. Its `path` names a file in
# `_delta_log/_sidecars/`, as the protocol requires sidecars to be.
sidecar_actions <- function(storage, sidecar, checkpoint) {
  path <- sidecar[["path"]]
  if (!is_string(path) || !nzchar(path) || grepl("/", path, fixed = TRUE)) {
    bad_action(
      checkpoint,
      "sidecar",
      "whose `path` is not a file name in `_delta_log/_sidecars/`"
    )
  }
  actions <- log_parquet_actions(
    storage,
    paste0(log_dir, "_sidecars/", percent_decode(path))
  )
  Filter(function(a) !is.null(a[["add"]]) || !is.null(a[["remove"]]), actions)
}

# The actions a checkpoint replays; the others (`commitInfo`, `cdc`,
# `checkpointMetadata`, statistics as structs) are not read.
checkpoint_actions <- c(
  "protocol",
  "metaData",
  "txn",
  "domainMetadata",
  "remove",
  "add",
  "sidecar"
)

# A field of an action that a JSON field of the same name could hold in its
# place, and that is not read: `stats_parsed` and `partitionValues_parsed`
# (statistics and partition values come from `stats` and `partitionValues`,
# as in a commit; design section 4.2).
parsed_field <- function(path) grepl("^[^.]+[.][^.]*_parsed$", path)

# One Parquet log file (a checkpoint, a part of one, or a sidecar) as a list
# of actions, one per row that holds one, in row order.
log_parquet_actions <- function(storage, path) {
  file <- if (is.function(storage$local_path)) {
    storage$local_path(path)
  } else {
    tmp <- tempfile(fileext = ".parquet")
    on.exit(unlink(tmp), add = TRUE)
    writeBin(storage$get(path), tmp)
    tmp
  }
  plan <- qio_read(qio::read_plan(file))
  leaves <- plan$path
  top <- sub("[.].*$", "", leaves)
  keep <- top %in% checkpoint_actions & grepl(".", leaves, fixed = TRUE)
  selectors <- unique(sub("^([^.]+[.][^.]+).*$", "\\1", leaves[keep]))
  selectors <- selectors[!parsed_field(selectors)]
  if (!length(selectors)) {
    return(list())
  }
  data <- read_log_parquet(file, selectors)
  parquet_actions(data)
}

# qio's read of the selected columns. A 64-bit integer that a double cannot
# hold makes qio warn and return NA: the file is read again with
# `int64 = "integer64"` when bit64 is installed, and is unreadable
# otherwise (D10).
read_log_parquet <- function(file, selectors) {
  lossy <- FALSE
  data <- withCallingHandlers(
    qio_read(qio::read_parquet(file, columns = selectors)),
    warning = function(w) {
      # Only qio's 64-bit coercion warning means a re-read with integer64
      # can help; any other (an INT32 of -2^31 read as NA) is the reason
      # the checkpoint is unreadable, as it says (#71).
      if (
        !grepl(
          "^Some INT64 or UINT64 values in column .* were coerced to NA",
          conditionMessage(w)
        )
      ) {
        checkpoint_refusal(conditionMessage(w))
      }
      lossy <<- TRUE
      invokeRestart("muffleWarning")
    }
  )
  if (!lossy) {
    return(data)
  }
  if (!has_bit64()) {
    checkpoint_refusal(
      paste(
        "it holds a 64-bit integer that a double cannot hold exactly, and",
        "reading it needs the bit64 package"
      )
    )
  }
  withCallingHandlers(
    qio_read(qio::read_parquet(file, columns = selectors, int64 = "integer64")),
    warning = function(w) checkpoint_refusal(conditionMessage(w))
  )
}

# The rows of a checkpoint read as actions: each row's non-null action
# columns, as list(<action> = <fields>), in row order.
parquet_actions <- function(data) {
  n <- nrow(data)
  actions <- vector("list", n)
  for (name in intersect(checkpoint_actions, names(data))) {
    col <- data[[name]]
    rows <- which(struct_present(col))
    values <- struct_values(col, rows)
    for (k in seq_along(rows)) {
      i <- rows[k]
      a <- actions[[i]]
      if (is.null(a)) {
        a <- list()
      }
      a[[name]] <- values[[k]]
      actions[[i]] <- a
    }
  }
  actions[!vapply(actions, is.null, NA)]
}

# Which rows of a struct column hold a value: those qio's null mask does not
# mark, for an optional struct; every row, for a required one.
struct_present <- function(col) {
  if (!is.data.frame(col)) {
    checkpoint_refusal("an action column is not a struct")
  }
  !qio::is_null_struct(col)
}

# The values of a struct column at `rows`, one named list per row in field
# order, without the fields that are null, or NULL for a null struct: what
# zujson gives for a JSON object that leaves out its null fields.
struct_values <- function(col, rows) {
  null <- qio::is_null_struct(col)[rows]
  fields <- lapply(col, column_values, rows = rows)
  out <- vector("list", length(rows))
  for (i in which(!null)) {
    row <- lapply(fields, `[[`, i)
    out[[i]] <- row[!vapply(row, is.null, NA)]
  }
  out
}

# One column's values at `rows`, as a list, NULL for null.
column_values <- function(col, rows) {
  if (is.data.frame(col)) {
    return(struct_values(col, rows))
  }
  if (is.list(col)) {
    return(lapply(col[rows], nested_value))
  }
  atomic_values(col[rows])
}

# A LIST (a vector) or a MAP (a key/value data frame) value, as zujson gives
# a JSON array or object: an empty array is logical(0), an object a named
# list with NULL for a null value. A MAP that holds a key twice is refused,
# as a JSON object would be (#102): a lookup by name would take the first
# (#108).
nested_value <- function(x) {
  if (is.null(x)) {
    return(NULL)
  }
  if (is.data.frame(x)) {
    keys <- as.character(x[["key"]])
    d <- anyDuplicated(keys)
    if (d) {
      checkpoint_refusal(
        sprintf("a map holds the key %s twice", format_string(keys[d]))
      )
    }
    values <- column_values(x[["value"]], seq_len(nrow(x)))
    names(values) <- keys
    return(values)
  }
  if (is.list(x)) {
    checkpoint_refusal("a list column holds a value zulake does not read")
  }
  if (!length(x)) {
    return(logical())
  }
  if (inherits(x, "integer64")) {
    # The JSON array a commit would hold, parsed the way a commit is.
    text <- as.character(x)
    text[is.na(text)] <- "null"
    return(
      parse_marked(paste0("{\"v\":[", paste(text, collapse = ","), "]}"))$v
    )
  }
  if (is.double(x) && all(is_int32_value(x[!is.na(x)]))) {
    return(as.integer(x))
  }
  x
}

# Whole numbers R's integer holds, which zujson parses as integers.
is_int32_value <- function(x) {
  x == trunc(x) & abs(x) <= .Machine$integer.max
}

# Atomic values as zujson gives the same JSON scalars: a whole number an R
# integer holds is an integer, one whose magnitude passes 2^53 - 1 a marked
# string (int64.R), any other number a double; NA is NULL.
atomic_values <- function(x) {
  n <- length(x)
  out <- vector("list", n)
  if (inherits(x, "integer64")) {
    text <- as.character(x)
    ok <- !is.na(text)
    big <- ok & integer_past_exact(ifelse(ok, text, "0"))
    out[big] <- lapply(text[big], make_marked)
    small <- ok & !big
    out[small] <- atomic_values(as.numeric(text[small]))
    return(out)
  }
  if (inherits(x, c("Date", "POSIXct"))) {
    checkpoint_refusal(
      "an action field has a date or time type, where the protocol has a long"
    )
  }
  ok <- !is.na(x)
  if (is.double(x)) {
    int <- ok & is_int32_value(x)
    big <- ok & !int & abs(x) > max_exact
    rest <- ok & !int & !big
    out[int] <- as.list(as.integer(x[int]))
    out[big] <- lapply(sprintf("%.0f", x[big]), make_marked)
    out[rest] <- as.list(x[rest])
    return(out)
  }
  out[ok] <- as.list(x[ok])
  out
}

#' The log itself
#'
#' Functions that return what `_delta_log/` holds, as data frames:
#'
#' * `lake_log()`: every entry of the `_delta_log/` listing taken when the
#'   snapshot was opened, including versions after the snapshot's.
#' * `lake_actions()`: every action of one commit, in file order.
#' * `lake_changes()`: the files added and removed between two versions.
#' * `lake_transactions()`: the latest `txn` action of each application.
#' * `lake_domains()`: the metadata domains in force (`domainMetadata`).
#' * `lake_checkpoints()`: the checkpoint files in the listing, and which
#'   one `_last_checkpoint` names.
#'
#' @inheritParams lake_files
#' @param version The version of the commit to return, a whole number. Its
#'   commit file must still be in the log.
#' @param from,to The two versions to compare, whole numbers with `from`
#'   at most `to`. `to` defaults to the snapshot's version.
#' @returns
#' `lake_log()`: a data frame `name`, `kind` (`"commit"`, `"checkpoint"`,
#' `"compaction"`, `"checksum"` or `"last_checkpoint"`), `version` (the
#' first version of a compaction file, `NA` for `_last_checkpoint`),
#' `end_version` (compaction files only), `part` and `parts` (multi-part
#' checkpoints only), `size` and `modification_time`, sorted by name.
#'
#' `lake_actions()`: a data frame with one row per action: `version`,
#' `line` (the action's line in the commit file), `type` (`"add"`,
#' `"remove"`, `"metaData"`, `"protocol"`, `"commitInfo"`, `"txn"`, or any
#' other name the log uses) and `action`, a list column holding the
#' action as the log writes it.
#'
#' `lake_changes()`: a data frame with the columns of
#' `lake_files(stats = FALSE)` after a first column `change`, `"added"` for
#' a file live at `to` and not at `from`, `"removed"` for the reverse. A
#' file is identified by its path and deletion vector, as the protocol
#' does, so a file given a new deletion vector is removed and added.
#'
#' `lake_transactions()`: a data frame `app_id`, `version` and
#' `last_updated` (`POSIXct`, `NA` when the action has none), sorted by
#' application.
#'
#' `lake_domains()`: a data frame `domain` and `configuration` (the
#' domain's configuration string, as the log writes it), sorted by domain.
#'
#' `lake_checkpoints()`: a data frame `version`, `name`, `type`
#' (`"classic"`, `"multi-part"` or `"v2"`), `part`, `parts`, `size`,
#' `modification_time` and `last_checkpoint` (whether `_last_checkpoint`
#' names this checkpoint's version), sorted by version and name.
#' @seealso [lake_versions()] for the table's versions and history.
#' @export
#' @examples
#' # The example table the package ships: orders partitioned by region, five versions.
#' path <- system.file("extdata", "orders", package = "zulake")
#' tbl <- lake_open(path)
#' lake_log(tbl)[c("name", "kind", "version", "size")]
#' lake_actions(tbl, version = 3)[c("line", "type")]
#' # Version 3 deleted order 5: one file removed, its other rows written again.
#' lake_changes(tbl, from = 2, to = 3)[c("change", "path")]
#' lake_transactions(tbl)
#' lake_domains(tbl)
#' lake_checkpoints(tbl)
lake_log <- function(tbl) {
  check_table(tbl)
  tbl$log
}

#' @rdname lake_log
#' @export
lake_actions <- function(tbl, version, int64 = c("double", "integer64")) {
  check_table(tbl)
  int64 <- check_int64(int64)
  if (missing(version) || is.null(version)) {
    zulake_abort("argument", "`version` must be a single whole number from 0 to 2^53 - 1.")
  }
  version <- check_version(version)
  log <- tbl$log
  hit <- log$kind == "commit" & log$version %in% version
  if (!any(hit)) {
    zulake_abort(
      "version",
      sprintf("the log has no commit file for version %s.", format_number(version)),
      version = version
    )
  }
  name <- log$name[hit][1L]
  actions <- read_actions(tbl$storage, name)
  rows <- lapply(seq_along(actions), function(i) {
    a <- actions[[i]]
    list(line = rep(i, length(a)), type = names(a), action = unname(as.list(a)))
  })
  what <- sprintf("an action of %s", name)
  action <- unlist(lapply(rows, `[[`, "action"), recursive = FALSE)
  new_data_frame(list(
    version = version_column(rep(version, length(action)), int64),
    line = as.integer(unlist(lapply(rows, `[[`, "line"))) %||% integer(),
    type = as.character(unlist(lapply(rows, `[[`, "type"))) %||% character(),
    action = lapply(action, unmark_tree, int64 = int64, what = what)
  ))
}

#' @rdname lake_log
#' @export
lake_changes <- function(tbl, from, to = lake_version(tbl), int64 = c("double", "integer64")) {
  check_table(tbl)
  int64 <- check_int64(int64)
  if (missing(from) || is.null(from)) {
    zulake_abort("argument", "`from` must be a single whole number from 0 to 2^53 - 1.")
  }
  from <- check_version(from)
  to <- check_version(to)
  if (is.null(to) || from > to) {
    zulake_abort("argument", "`to` must be a whole number at least `from`.")
  }
  snap <- function(v) if (v == tbl$version) tbl else lake_load(tbl, version = v)
  a <- snap(from)
  b <- snap(to)
  key <- function(s) {
    if (!nrow(s$files)) character() else paste0(s$files$path, "\x1f", s$files$deletion_vector_id)
  }
  ka <- key(a)
  kb <- key(b)
  added <- add_frame(b, b$files$action[!kb %in% ka], FALSE, int64)
  removed <- add_frame(a, a$files$action[!ka %in% kb], FALSE, int64)
  out <- rbind_frames(added, removed)
  out <- c(list(change = rep(c("added", "removed"), c(nrow(added), nrow(removed)))), out)
  new_data_frame_n(out, nrow(added) + nrow(removed))
}

#' @rdname lake_log
#' @export
lake_transactions <- function(tbl, int64 = c("double", "integer64")) {
  check_table(tbl)
  int64 <- check_int64(int64)
  txns <- tbl$transactions
  updated <- int64_values(lapply(txns, function(x) x[["lastUpdated"]]), "double", "a `txn`'s `lastUpdated`")
  new_data_frame(list(
    app_id = names(txns),
    version = int64_values(lapply(txns, function(x) x[["version"]]), int64, "a `txn`'s `version`"),
    last_updated = ms_to_posixct(updated)
  ))
}

#' @rdname lake_log
#' @export
lake_domains <- function(tbl) {
  check_table(tbl)
  d <- tbl$domains
  new_data_frame(list(
    domain = names(d),
    configuration = vapply(d, function(x) x[["configuration"]], "", USE.NAMES = FALSE)
  ))
}

#' @rdname lake_log
#' @export
lake_checkpoints <- function(tbl) {
  check_table(tbl)
  log <- tbl$log
  cp <- log[log$kind == "checkpoint", , drop = FALSE]
  cp <- cp[order(cp$version, cp$name, method = "radix"), , drop = FALSE]
  type <- ifelse(!is.na(cp$parts), "multi-part",
    ifelse(grepl("[.]checkpoint[.][0-9a-fA-F-]{36}[.]", cp$name), "v2", "classic")
  )
  last <- tbl$last_checkpoint
  new_data_frame(list(
    version = cp$version,
    name = cp$name,
    type = type,
    part = cp$part,
    parts = cp$parts,
    size = cp$size,
    modification_time = cp$modification_time,
    last_checkpoint = if (is.null(last)) rep(FALSE, nrow(cp)) else cp$version == last[["version"]]
  ))
}

# Two data frames with the same columns, one after the other, list columns
# and classed vectors (POSIXct, integer64) kept.
rbind_frames <- function(a, b) {
  out <- lapply(names(a), function(nm) {
    x <- a[[nm]]
    y <- b[[nm]]
    r <- c(x, y)
    if (inherits(x, "POSIXct")) attr(r, "tzone") <- "UTC"
    r
  })
  names(out) <- names(a)
  out
}

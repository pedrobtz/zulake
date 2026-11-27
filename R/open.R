#' Open a table
#'
#' `lake_open()` builds a snapshot of a Delta Lake table: one version of it,
#' replayed from the table's own log as the Delta protocol prescribes. A
#' snapshot never changes; `lake_load()` builds another one of the same
#' table, at another version or at the version the log now ends at.
#'
#' The snapshot holds the version's protocol, metadata, live files,
#' tombstones, application transactions and metadata domains. It is checked
#' before it is returned: a table that needs a reader feature zulake does
#' not support is refused with an error naming that feature, before any data
#' file is read, because ignoring a feature returns wrong rows.
#'
#' zulake reads tables on local disk and on Azure (Blob Storage and Data
#' Lake Storage Gen2), replaying the log from the latest checkpoint at or
#' before the version (classic, multi-part or V2, with its sidecars), or
#' from the first commit when there is none. A checkpoint that cannot be
#' read is passed over for an earlier one or for the commits; a version
#' that needs it, in a log that no longer reaches commit 0, is refused with
#' a `zulake_error_checkpoint_unreadable` error. A version whose commits
#' were cleaned up, older than the earliest checkpoint, is a
#' `zulake_error_version` error. A file's `dataChange` from a checkpoint is
#' the checkpoint's copy, which some writers set to `FALSE`.
#'
#' @section Azure:
#' A table on Azure is given by one of three URI forms, which all reach the
#' same blobs through the Blob service API:
#'
#' * `abfss://<container>@<account>.dfs.core.windows.net/<path>`
#' * `https://<account>.dfs.core.windows.net/<container>/<path>`
#' * `https://<account>.blob.core.windows.net/<container>/<path>`
#'
#' Other schemes (`s3://`, `gs://`, `abfs://`, `http://`, ...) are refused
#' with a `zulake_error_uri` error, and so is a URI with a query string,
#' such as a SAS: zulake authenticates with a bearer token only.
#'
#' `credentials` is a function you write, which zulake calls with no
#' arguments to get a Microsoft Entra ID access token for Azure Storage
#' (audience `https://storage.azure.com`), as a string. zulake does not
#' obtain tokens itself: return one from the Azure CLI, a managed identity
#' or a package such as AzureAuth. It is called before the first request,
#' and once more when Azure answers `401` (an expired token); a second
#' `401`, or a `403`, is a `zulake_error_auth` error. The token is sent only
#' in the `Authorization` header: it is not kept in the snapshot, printed,
#' or put in any error. Without `credentials`, requests are anonymous, which
#' only a public container answers.
#'
#' A file the log names by an absolute Azure URI is read only when it is
#' in the table's own account and container; one elsewhere is a
#' `zulake_error_uri` error, and no request is sent there.
#'
#' The snapshot does not keep `credentials` either; later calls on it, such
#' as [lake_read()], use it through the R session. A snapshot saved with
#' [saveRDS()] and read in another session has none: open the table again.
#'
#' @param uri Location of the table, the directory that holds `_delta_log/`:
#'   a local path, or an Azure URI in one of the forms of the Azure section.
#' @param version Version to open, a whole number. `NULL`, the default, is
#'   the latest version.
#' @param timestamp Open the latest version committed at or before this
#'   time, a `POSIXct`. The commit time is the commit's in-commit timestamp
#'   when the table records them, and the commit file's modification time
#'   otherwise, made increasing as [lake_versions()] describes. A time
#'   before the first commit opens the first version; a log with no commit
#'   file (checkpoints alone) has no commit times, and is a
#'   `zulake_error_version`. Give `version` or `timestamp`, not both.
#' @param credentials A function of no arguments returning a bearer token
#'   for Azure Storage, as a string (see the Azure section), or `NULL` for
#'   anonymous requests. Not used for local paths.
#' @returns `lake_open()` and `lake_load()` return a snapshot, an object of
#'   class `zulake_table`. `lake_version()` returns the version a snapshot
#'   holds, a whole number as a double.
#'
#'   Every error is a condition of class `zulake_error`, with a subclass
#'   that says why: `zulake_error_argument` (an argument of the wrong type
#'   or value, such as a `version` that is not a whole number),
#'   `zulake_error_not_table` (no Delta log at `uri`),
#'   `zulake_error_version` (no such version, or one no longer in the log),
#'   `zulake_error_uri` (a URI zulake cannot open), `zulake_error_storage` (a file that cannot be
#'   read; from Azure with the HTTP `status` and Azure's error `code`),
#'   `zulake_error_auth` (credentials refused), `zulake_error_corrupt_log`
#'   (a log that breaks the protocol, such as a commit that is not JSON or a
#'   partition value of the wrong type, or a `_last_checkpoint` naming a
#'   checkpoint the log does not hold whole),
#'   `zulake_error_checkpoint_unreadable` (its `checkpoint` field gives the version, `parent` the read failure)
#'   and `zulake_error_unsupported_feature`, whose `feature` field names the
#'   feature.
#' @seealso [lake_is_table()] to check a location first.
#' @export
#' @examples
#' # The example table the package ships: orders partitioned by region, five versions.
#' path <- system.file("extdata", "orders", package = "zulake")
#' tbl <- lake_open(path)
#' tbl
#' lake_version(tbl)
#'
#' # An older version, by number or by the time it was committed:
#' lake_version(lake_open(path, version = 1))
#' lake_version(lake_load(tbl, timestamp = as.POSIXct("2025-01-08 12:00", tz = "UTC")))
#'
#' # On Azure: a token for Azure Storage from the Azure CLI. Not run, because
#' # it needs an Azure account and a signed-in CLI.
#' \dontrun{
#' token <- function() {
#'   system2("az", c(
#'     "account", "get-access-token", "--resource", "https://storage.azure.com",
#'     "--query", "accessToken", "--output", "tsv"
#'   ), stdout = TRUE)
#' }
#' tbl <- lake_open("abfss://lake@myaccount.dfs.core.windows.net/sales", credentials = token)
#' lake_files(tbl)
#' }
lake_open <- function(uri, version = NULL, timestamp = NULL, credentials = NULL) {
  storage <- storage_for(uri, credentials)
  snapshot_build(storage, uri, check_version(version), check_timestamp(timestamp))
}

#' @rdname lake_open
#' @param tbl A snapshot, from `lake_open()` or `lake_load()`.
#' @export
lake_load <- function(tbl, version = NULL, timestamp = NULL) {
  check_table(tbl)
  snapshot_build(tbl$storage, tbl$uri, check_version(version), check_timestamp(timestamp))
}

#' Is there a table here?
#'
#' `lake_is_table()` says whether `uri` holds a Delta Lake table: a
#' `_delta_log/` directory with at least one commit or checkpoint in it. It
#' reads no log file, so a table it finds can still fail to open.
#'
#' @inheritParams lake_open
#' @returns `TRUE` or `FALSE`.
#' @seealso [lake_open()], whose example also calls `lake_is_table()`.
#' @export
#' @examples
#' lake_is_table(system.file("extdata", "orders", package = "zulake"))
#' lake_is_table(tempdir())
lake_is_table <- function(uri, credentials = NULL) {
  storage <- storage_for(uri, credentials)
  entries <- log_entries(storage$list(log_dir))
  any(entries$kind %in% c("commit", "checkpoint"))
}

#' @rdname lake_open
#' @export
lake_version <- function(tbl) {
  check_table(tbl)
  tbl$version
}

# ---- the snapshot --------------------------------------------------------

# A snapshot (class `zulake_table`) is a list:
#
#   format           "delta" (D11: the class is named for a table, not for
#                    Delta, and records its format)
#   uri              the location as given
#   version          the snapshot's version, a double
#   timestamp        that version's commit time, POSIXct in UTC
#   protocol         the `protocol` action in force, as parsed
#   metadata         the `metaData` action in force, as parsed, plus `schema`
#                    (its `schemaString` parsed)
#   column_mapping   "none" or "name"
#   files            live files: data frame `path`, `deletion_vector_id`
#                    ("" for none) and `action` (list column of the `add`
#                    actions, as parsed), sorted by path and id in byte order
#   removed          tombstones, in the same shape (`action` holds the
#                    `remove` actions)
#   transactions     list of `txn` actions by `appId`, latest each
#   domains          list of `domainMetadata` actions by domain, removed ones
#                    left out
#   commit_info      the snapshot version's `commitInfo` action, or NULL
#   log              the `_delta_log/` listing at open time (log_entries())
#   last_checkpoint  `_last_checkpoint`, parsed, or NULL
#   storage          the storage backend (storage.R)
snapshot_build <- function(storage, uri, version = NULL, timestamp = NULL) {
  if (!is.null(version) && !is.null(timestamp)) {
    zulake_abort("argument", "Give `version` or `timestamp`, not both.")
  }
  entries <- log_entries(storage$list(log_dir))
  if (!any(entries$kind %in% c("commit", "checkpoint"))) {
    zulake_abort(
      "not_table",
      sprintf("%s is not a Delta table: it has no `_delta_log/` with a commit in it.", format_string(uri)),
      uri = uri
    )
  }
  sets <- checkpoint_sets(entries)
  commits <- entries$version[entries$kind == "commit"]
  whole <- vapply(sets, function(s) s$version[1L], 0)
  if (!length(commits) && !length(whole)) {
    zulake_abort(
      "checkpoint_unreadable",
      sprintf("%s has no commits, and no checkpoint that is whole.", format_string(uri)),
      checkpoint = max(entries$version[entries$kind == "checkpoint"])
    )
  }
  latest <- max(commits, whole)
  last_checkpoint <- read_last_checkpoint(storage, entries)
  if (!is.null(last_checkpoint)) {
    named <- last_checkpoint[["version"]]
    if (named > latest) {
      zulake_abort(
        "corrupt_log",
        sprintf(
          "_last_checkpoint names version %s, but the log ends at version %s.",
          format_number(named), format_number(latest)
        )
      )
    }
    if (!named %in% whole) {
      zulake_abort(
        "corrupt_log",
        sprintf(
          "_last_checkpoint names the checkpoint at version %s, which the log does not hold whole.",
          format_number(named)
        ),
        checkpoint = named
      )
    }
  }

  cache <- new.env(parent = emptyenv())
  read <- function(name) {
    if (is.null(cache[[name]])) {
      cache[[name]] <- read_actions(storage, name)
    }
    cache[[name]]
  }
  cp_cache <- new.env(parent = emptyenv())
  read_cp <- function(set) {
    key <- set$name[1L]
    if (is.null(cp_cache[[key]])) {
      cp_cache[[key]] <- list(read_checkpoint(storage, set, read))
    }
    cp_cache[[key]][[1L]]
  }
  state_at <- function(v) replay_state(entries, sets, v, read, read_cp)

  state <- NULL
  if (!is.null(timestamp)) {
    # The latest snapshot says whether commits carry in-commit timestamps,
    # so it must itself be one zulake can read.
    state <- state_at(latest)
    check_reader_features(state$protocol, state$metadata, latest)
    version <- version_at(timestamp, entries, state$protocol, state$metadata, read)
    if (version != latest) state <- NULL
  } else if (is.null(version)) {
    version <- latest
  } else if (version > latest) {
    zulake_abort(
      "version",
      sprintf(
        "%s has no version %s: its log ends at version %s.",
        format_string(uri), format_number(version), format_number(latest)
      ),
      version = version
    )
  }
  if (is.null(state)) {
    state <- state_at(version)
  }

  check_reader_features(state$protocol, state$metadata, version)
  mode <- column_mapping_mode(state$protocol, state$metadata)
  check_physical_names(state$metadata, mode)
  files <- file_frame(state$adds)
  check_partition_values(files$action, state$metadata, mode)

  entry <- entries[entries$kind == "commit" & entries$version == version, , drop = FALSE]
  commit_info <- NULL
  time <- NA_real_
  if (nrow(entry)) {
    actions <- read(entry$name)
    for (a in actions) {
      if (!is.null(a[["commitInfo"]])) {
        commit_info <- a[["commitInfo"]]
        break
      }
    }
    commits <- listing_commits(entries)
    commits <- commits[commits$version <= version, , drop = FALSE]
    time <- commit_times_ms(commits, ict_info(state$protocol, state$metadata), read, nrow(commits))
  }

  structure(
    list(
      format = "delta",
      uri = uri,
      version = version,
      timestamp = ms_to_posixct(time),
      protocol = state$protocol,
      metadata = state$metadata,
      column_mapping = mode,
      files = files,
      removed = file_frame(state$removes),
      transactions = sort_by_name(state$txns),
      domains = sort_by_name(state$domains),
      commit_info = commit_info,
      log = entries,
      last_checkpoint = last_checkpoint,
      storage = storage
    ),
    class = "zulake_table"
  )
}

# A named list in byte order of its names; an empty one stays an empty
# named list.
sort_by_name <- function(x) {
  if (!length(x)) {
    return(structure(list(), names = character()))
  }
  x[order(names(x), method = "radix")]
}

# The file actions held in a replay environment, as a data frame sorted by
# path, then deletion vector id, in byte order.
file_frame <- function(env) {
  actions <- mget(ls(env, all.names = TRUE, sorted = FALSE), envir = env)
  path <- vapply(actions, function(a) a[["path"]], "", USE.NAMES = FALSE)
  dv <- vapply(actions, function(a) dv_unique_id(a[["deletionVector"]]), "", USE.NAMES = FALSE)
  ord <- order(path, dv, method = "radix")
  new_data_frame(list(
    path = path[ord],
    deletion_vector_id = dv[ord],
    action = unname(actions)[ord]
  ))
}

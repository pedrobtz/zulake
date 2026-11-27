# The storage interface (design section 4.1).
#
# A backend is a list of functions over paths relative to the table root,
# with "/" as separator:
#
#   list(prefix, after = NULL)  the files directly under `prefix` (a
#                               directory path ending in "/"), as a data
#                               frame `name`, `size`, `modification_time`
#                               (POSIXct, UTC), sorted by name in byte
#                               order; with `after`, only names that sort
#                               after it
#   get(path)                   the whole file, as a raw vector
#   get_range(path, from, to)   bytes `from` to `to` inclusive, 0-based, as
#                               an HTTP Range header counts them
#   head(path)                  list(size, modification_time), or NULL when
#                               there is no such file
#   local_path(path)            (optional) the file's path on local disk;
#                               a backend without it has its data files
#                               downloaded through get() to the
#                               snapshot's download cache (read.R)
#
# plus `kind` ("local" or "azure") and `root`. The Azure backend (azure.R)
# also has `location`. The interface stays internal, so a later backend (a
# future zustore) changes no public function.

storage_for <- function(uri, credentials = NULL) {
  check_string(uri, "uri")
  if (!is.null(credentials) && !is.function(credentials)) {
    zulake_abort("argument", "`credentials` must be NULL or a function of no arguments.")
  }
  if (grepl("^[A-Za-z][A-Za-z0-9+.-]*://", uri)) {
    if (is_azure_uri(uri)) {
      parts <- parse_azure_uri(uri)
      return(storage_azure(parts, credential_handle(credentials, parts$uri)))
    }
    scheme <- sub("://.*$", "", uri)
    zulake_abort(
      "uri",
      sprintf(
        paste(
          "zulake cannot open %s URIs: only local paths and Azure URIs",
          "(abfss://<container>@<account>.dfs.core.windows.net/<path>,",
          "https://<account>.dfs.core.windows.net/<container>/<path> and",
          "https://<account>.blob.core.windows.net/<container>/<path>) are supported."
        ),
        format_string(scheme)
      ),
      scheme = scheme
    )
  }
  storage_local(uri)
}

storage_local <- function(root) {
  root <- normalizePath(path.expand(root), winslash = "/", mustWork = FALSE)
  full <- function(path) file.path(root, path)

  list_files <- function(prefix, after = NULL) {
    dir <- full(prefix)
    files <- if (dir.exists(dir)) list.files(dir, all.files = TRUE, no.. = TRUE) else character()
    info <- file.info(file.path(dir, files), extra_cols = FALSE)
    keep <- !is.na(info$isdir) & !info$isdir
    files <- files[keep]
    info <- info[keep, , drop = FALSE]
    if (!is.null(after)) {
      check_string(after, "after")
      later <- sorts_after(files, after)
      files <- files[later]
      info <- info[later, , drop = FALSE]
    }
    ord <- order(files, method = "radix")
    new_data_frame(list(
      name = files[ord],
      size = as.numeric(info$size[ord]),
      modification_time = as_utc(info$mtime[ord])
    ))
  }

  get <- function(path) {
    f <- full(path)
    size <- file.size(f)
    if (is.na(size) || dir.exists(f)) {
      abort_no_file(path)
    }
    readBin(f, "raw", size)
  }

  get_range <- function(path, from, to) {
    f <- full(path)
    size <- file.size(f)
    if (is.na(size) || dir.exists(f)) {
      abort_no_file(path)
    }
    ok <- is_whole(from) && is_whole(to) && from >= 0 && to >= from && to < size
    if (!ok) {
      zulake_abort(
        "storage",
        sprintf(
          "cannot read bytes %s to %s of %s, which has %s.",
          format_number(from), format_number(to), format_string(path), format_number(size)
        ),
        path = path
      )
    }
    con <- file(f, "rb")
    on.exit(close(con))
    seek(con, from)
    readBin(con, "raw", to - from + 1)
  }

  head <- function(path) {
    f <- full(path)
    info <- file.info(f, extra_cols = FALSE)
    if (is.na(info$isdir) || info$isdir) {
      return(NULL)
    }
    list(size = as.numeric(info$size), modification_time = as_utc(info$mtime))
  }

  # A file's path on this disk, for a reader that needs one (qio reads
  # paths): the same file `get()` would return, without a copy.
  local_path <- function(path) {
    f <- full(path)
    if (!file.exists(f) || dir.exists(f)) {
      abort_no_file(path)
    }
    f
  }

  list(
    kind = "local", root = root, list = list_files, get = get, get_range = get_range, head = head,
    local_path = local_path
  )
}

# `x > y` in byte order, whatever the session's collation.
sorts_after <- function(x, y) {
  if (!length(x)) {
    return(logical())
  }
  values <- unique(c(y, x))
  rank <- match(values, values[order(values, method = "radix")])
  rank[match(x, values)] > rank[1L]
}

as_utc <- function(x) {
  x <- as.POSIXct(x)
  attr(x, "tzone") <- "UTC"
  x
}

# The error for a file the backend does not have; `...` adds fields (the
# Azure backend's `status`).
abort_no_file <- function(path, ...) {
  zulake_abort("storage", sprintf("cannot read %s: no such file.", format_string(path)), path = path, ...)
}

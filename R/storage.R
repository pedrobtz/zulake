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
#
# plus `kind` ("local") and `root`. The interface stays internal, so a later
# backend (Azure in Stage 6, a future zustore) changes no public function.

storage_for <- function(uri, credentials = NULL) {
  check_string(uri, "uri")
  if (!is.null(credentials) && !is.function(credentials)) {
    zulake_abort("argument", "`credentials` must be NULL or a function of no arguments.")
  }
  if (grepl("^[A-Za-z][A-Za-z0-9+.-]*://", uri)) {
    scheme <- sub("://.*$", "", uri)
    zulake_abort(
      "uri",
      sprintf(
        "zulake cannot open %s URIs yet: only local paths are supported.",
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
    names <- if (dir.exists(dir)) list.files(dir, all.files = TRUE, no.. = TRUE) else character()
    info <- file.info(file.path(dir, names), extra_cols = FALSE)
    keep <- !is.na(info$isdir) & !info$isdir
    names <- names[keep]
    info <- info[keep, , drop = FALSE]
    if (!is.null(after)) {
      check_string(after, "after")
      later <- sorts_after(names, after)
      names <- names[later]
      info <- info[later, , drop = FALSE]
    }
    ord <- order(names, method = "radix")
    new_data_frame(list(
      name = names[ord],
      size = as.numeric(info$size[ord]),
      modification_time = as_utc(info$mtime[ord])
    ))
  }

  get <- function(path) {
    f <- full(path)
    size <- file.size(f)
    if (is.na(size) || dir.exists(f)) {
      zulake_abort("storage", sprintf("cannot read %s: no such file.", format_string(path)), path = path)
    }
    readBin(f, "raw", size)
  }

  get_range <- function(path, from, to) {
    f <- full(path)
    size <- file.size(f)
    if (is.na(size) || dir.exists(f)) {
      zulake_abort("storage", sprintf("cannot read %s: no such file.", format_string(path)), path = path)
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

  list(kind = "local", root = root, list = list_files, get = get, get_range = get_range, head = head)
}

# `x > y` in byte order, whatever the session's collation.
sorts_after <- function(x, y) {
  if (!length(x)) {
    return(logical())
  }
  all <- unique(c(y, x))
  rank <- match(all, all[order(all, method = "radix")])
  rank[match(x, all)] > rank[1L]
}

as_utc <- function(x) {
  x <- as.POSIXct(x)
  attr(x, "tzone") <- "UTC"
  x
}

new_data_frame <- function(cols) {
  n <- if (length(cols)) length(cols[[1L]]) else 0L
  structure(cols, class = "data.frame", row.names = .set_row_names(n))
}

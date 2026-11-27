# The Azure backend of the storage interface (design section 4.1), over the
# Blob service REST API through zuhttp (D5). One code path serves Blob
# Storage and ADLS Gen2 (hierarchical namespace) accounts, whose `dfs`
# URIs the Blob endpoint serves too:
#
#   abfss://<container>@<account>.dfs.core.windows.net/<path>
#   https://<account>.dfs.core.windows.net/<container>/<path>
#   https://<account>.blob.core.windows.net/<container>/<path>
#
# Requests: List Blobs (`restype=container&comp=list`, `prefix`,
# `delimiter=/`, `marker` until the last page), Get Blob (with `Range` for
# get_range()), Get Blob Properties (HEAD). Each carries `x-ms-version`
# (azure_version) and, with credentials, `Authorization: Bearer <token>`.
#
# The token never leaves the request (D4, CLAUDE.md): `credentials()` is
# called before the first request and once more after a 401, and its token
# is kept in `credential_env`, keyed by an id. A snapshot holds only a handle
# with that id, never the token or the `credentials` function, so neither
# is printed, serialized or put in a condition. A handle's entry goes when
# the handle is garbage-collected; a snapshot restored in another session
# finds none and asks for lake_open() again (zulake_error_auth).
#
# Two internal options, for tests (design section 8):
#   zulake.azure_endpoint  a Blob endpoint that replaces
#                          https://<account>.blob.core.windows.net for every
#                          account, such as Azurite's path-style
#                          https://127.0.0.1:10000/devstoreaccount1; read
#                          when the backend is made
#   zulake.azure_client    the zuhttp client to send requests with (a mock,
#                          a cassette, a client trusting Azurite's CA); read
#                          at each request

# The Blob service version every request asks for: the one object_store,
# deltalake's storage layer, sends.
azure_version <- "2023-11-03"

# ---- URIs ----------------------------------------------------------------

# Whether `uri` is one of the three Azure forms, by scheme and host only.
is_azure_uri <- function(uri) {
  grepl(
    "^abfss://[^/]*@[^/]*[.]dfs[.]core[.]windows[.]net(/|$)",
    uri,
    ignore.case = TRUE
  ) ||
    grepl(
      "^https://[^/]*[.](blob|dfs)[.]core[.]windows[.]net(/|$)",
      uri,
      ignore.case = TRUE
    )
}

# The parts of an Azure URI: account, container, path (the table's blob
# prefix, percent-decoded, without leading or trailing "/") and `uri`
# (the URI without trailing "/"). Every refusal is a zulake_error_uri; a
# refusal never repeats a query string or user information, which may hold
# a secret.
parse_azure_uri <- function(uri) {
  if (grepl("[?#]", uri)) {
    zulake_abort(
      "uri",
      paste(
        "An Azure URI must not have a query string or a fragment:",
        "zulake authenticates with a bearer token from `credentials`, not a SAS."
      )
    )
  }
  if (grepl("^abfss://", uri, ignore.case = TRUE)) {
    m <- regmatches(
      uri,
      regexec(
        "^abfss://([^/@]*)@([^/]*)[.]dfs[.]core[.]windows[.]net(/.*)?$",
        uri,
        ignore.case = TRUE
      )
    )[[1L]]
    # Where abfss has its container, a ":" makes user information with a
    # password, which is neither quoted nor kept with the condition (#48).
    if (length(m) && grepl(":", m[2L], fixed = TRUE)) {
      m <- character()
    }
    container <- m[2L]
    account <- tolower(m[3L])
    path <- m[4L]
  } else {
    m <- regmatches(
      uri,
      regexec(
        "^https://([^/]*)[.](blob|dfs)[.]core[.]windows[.]net(/([^/]*)(/.*)?)?$",
        uri,
        ignore.case = TRUE
      )
    )[[1L]]
    account <- tolower(m[2L])
    container <- m[5L]
    path <- m[6L]
  }
  if (!length(m) || grepl("@", account)) {
    zulake_abort(
      "uri",
      "An Azure URI must not hold user information; give a token through `credentials`."
    )
  }
  if (!grepl("^[a-z0-9]{3,24}$", account)) {
    zulake_abort(
      "uri",
      sprintf(
        "%s is not an Azure storage account name: 3 to 24 lowercase letters and digits.",
        format_string(account)
      ),
      uri = uri
    )
  }
  if (
    !grepl(
      "^[a-z0-9]([a-z0-9]|-(?!-)){1,61}[a-z0-9]$",
      container,
      perl = TRUE
    ) &&
      container != "$root"
  ) {
    zulake_abort(
      "uri",
      sprintf(
        "%s is not an Azure container name: 3 to 63 lowercase letters, digits and single hyphens.",
        format_string(container)
      ),
      uri = uri
    )
  }
  # The separator after the container, and one trailing "/", are not
  # segments; any other empty segment is refused, as "." and ".." are (#61).
  path <- sub("^/", "", path)
  trailing <- endsWith(path, "/")
  path <- percent_decode(sub("/$", "", path), "uri")
  if (
    (trailing && !nzchar(path)) ||
      endsWith(path, "/") ||
      (nzchar(path) &&
        any(strsplit(path, "/", fixed = TRUE)[[1L]] %in% c("", ".", "..")))
  ) {
    zulake_abort(
      "uri",
      sprintf(
        "%s has an empty, \".\" or \"..\" path segment.",
        format_string(uri)
      ),
      uri = uri
    )
  }
  list(
    account = account,
    container = container,
    path = unname(path),
    uri = sub("/+$", "", uri)
  )
}

# The Blob endpoint for `account`: zulake.azure_endpoint when set.
azure_endpoint <- function(account) {
  endpoint <- getOption("zulake.azure_endpoint")
  if (is.null(endpoint)) {
    return(sprintf("https://%s.blob.core.windows.net", account))
  }
  if (!is_string(endpoint) || !grepl("^https?://", endpoint)) {
    zulake_abort(
      "argument",
      "Option `zulake.azure_endpoint` must be NULL or an http(s) URL."
    )
  }
  sub("/+$", "", endpoint)
}

# A blob name as a URL path: each segment percent-encoded, "/" kept.
blob_path_url <- function(name) {
  segments <- strsplit(name, "/", fixed = TRUE)[[1L]]
  paste(vapply(segments, url_encode, "", USE.NAMES = FALSE), collapse = "/")
}

# RFC 3986 percent-encoding of everything but the unreserved characters, by
# UTF-8 byte, whatever the session's locale.
url_encode <- function(x) {
  bytes <- charToRaw(enc2utf8(x))
  keep <- bytes %in% unreserved_bytes
  out <- character(length(bytes))
  out[keep] <- rawToChar(bytes[keep], multiple = TRUE)
  out[!keep] <- sprintf("%%%02X", as.integer(bytes[!keep]))
  paste(out, collapse = "")
}

unreserved_bytes <- charToRaw(
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
)

# ---- credentials ---------------------------------------------------------

# Made in .onLoad() (zulake-package.R, which says why), not here.
# `credential_env` holds the entries and nothing else; `credential_state`
# the session's nonce and counter.
credential_env <- NULL
credential_state <- NULL

# A handle on `credentials` (a function, or NULL for anonymous requests)
# for the table at `root` (its URI): an environment holding only an id and
# that root; the function and its token live in credential_env until the
# handle is garbage-collected. The id is a random 128-bit nonce made once
# per session followed by a counter, so that no two sessions make the same
# id: a snapshot restored in another session finds no entry (#43). The
# entry keeps the root too, and a handle whose root is not its entry's
# gets no token.
credential_handle <- function(credentials, root) {
  if (is.null(credential_state$nonce)) {
    credential_state$nonce <- random_hex(16L)
  }
  credential_state$n <- (credential_state$n %||% 0) + 1
  id <- paste0(credential_state$nonce, "-", format_number(credential_state$n))
  handle <- new.env(parent = emptyenv())
  handle$id <- id
  handle$root <- root
  assign(
    id,
    list(fn = credentials, token = NULL, root = root),
    envir = credential_env
  )
  reg.finalizer(handle, credential_release)
  handle
}

# `n` random bytes as hexadecimal: from the system's generator where there
# is one, else from R's, seeded afresh from the clock and the process id and
# leaving the session's own random stream (`.Random.seed`) as it was.
random_hex <- function(n) {
  bytes <- tryCatch(
    system_random_bytes(n),
    error = function(e) raw(),
    warning = function(w) raw()
  )
  if (length(bytes) != n) {
    genv <- globalenv()
    had <- exists(".Random.seed", envir = genv, inherits = FALSE)
    old <- if (had) get(".Random.seed", envir = genv, inherits = FALSE)
    on.exit(
      if (had) {
        assign(".Random.seed", old, envir = genv)
      } else {
        rm(".Random.seed", envir = genv)
      }
    )
    if (had) {
      rm(".Random.seed", envir = genv)
    }
    bytes <- as.raw(sample.int(256L, n, replace = TRUE) - 1L)
  }
  paste(sprintf("%02x", as.integer(bytes)), collapse = "")
}

system_random_bytes <- function(n) {
  if (!file.exists("/dev/urandom")) {
    return(raw())
  }
  con <- file("/dev/urandom", "rb", raw = TRUE)
  on.exit(close(con))
  readBin(con, "raw", n)
}

credential_release <- function(handle) {
  id <- handle$id
  if (is_string(id) && exists(id, envir = credential_env, inherits = FALSE)) {
    rm(list = id, envir = credential_env)
  }
  invisible(NULL)
}

credential_entry <- function(handle) {
  id <- if (is.environment(handle)) handle$id
  root <- if (is.environment(handle)) handle$root
  entry <- if (
    is_string(id) && exists(id, envir = credential_env, inherits = FALSE)
  ) {
    get(id, envir = credential_env, inherits = FALSE)
  }
  if (is.null(entry) || !is_string(root) || !identical(entry$root, root)) {
    zulake_abort(
      "auth",
      paste(
        "This snapshot's credentials are not in this R session (it was saved and restored):",
        "open the table again with lake_open()."
      )
    )
  }
  entry
}

# The bearer token to send, or NULL for anonymous requests. `refresh`
# calls credentials() again, after a 401.
credential_token <- function(handle, refresh = FALSE) {
  entry <- credential_entry(handle)
  if (is.null(entry$fn)) {
    return(NULL)
  }
  if (!refresh && !is.null(entry$token)) {
    return(entry$token)
  }
  token <- tryCatch(entry$fn(), error = function(e) {
    zulake_abort(
      "auth",
      sprintf("`credentials()` failed: %s", conditionMessage(e))
    )
  })
  # A leading "Bearer " (any case) is the header's, not the token's: dropped
  # before the token is checked, so that "Bearer " alone is no token (#47).
  if (is_string(token)) {
    token <- sub("^[Bb][Ee][Aa][Rr][Ee][Rr] +", "", token)
  }
  if (
    !is_string(token) || !nzchar(token) || grepl("[[:cntrl:][:space:]]", token)
  ) {
    zulake_abort(
      "auth",
      paste(
        "`credentials()` must return a bearer token: a single non-empty string",
        "without spaces or control characters."
      )
    )
  }
  entry$token <- token
  assign(handle$id, entry, envir = credential_env)
  token
}

# ---- requests ------------------------------------------------------------

azure_env <- new.env(parent = emptyenv())

# The client requests go out with: zulake.azure_client, or one zuhttp
# client per session, whose pool keeps connections open between requests.
azure_client <- function() {
  client <- getOption("zulake.azure_client")
  if (!is.null(client)) {
    if (!inherits(client, "zu_client")) {
      zulake_abort(
        "argument",
        "Option `zulake.azure_client` must be NULL or a zuhttp client."
      )
    }
    return(client)
  }
  if (is.null(azure_env$client)) {
    azure_env$client <- zuhttp::zu_client(
      user_agent = paste0("zulake/", utils::packageVersion("zulake"))
    )
  }
  azure_env$client
}

# Seconds a request may take, a download included.
azure_timeout <- 600

# One request, with the token, retried once with a fresh token after a 401
# (D4). `path` is the blob name, for messages; `query` a named list;
# `range` c(from, to). Returns the response, whatever its status; a
# transport failure is a zulake_error_storage that keeps zuhttp's message
# and class, not its request.
azure_request <- function(
  loc,
  method,
  blob,
  query = NULL,
  range = NULL,
  path = blob
) {
  url <- paste0(loc$endpoint, "/", url_encode(loc$container))
  if (nzchar(blob)) {
    url <- paste0(url, "/", blob_path_url(blob))
  }
  headers <- c(`x-ms-version` = azure_version)
  if (!is.null(range)) {
    headers <- c(
      headers,
      Range = sprintf(
        "bytes=%s-%s",
        format_number(range[1L]),
        format_number(range[2L])
      )
    )
  }
  for (attempt in 1:2) {
    token <- credential_token(loc$handle, refresh = attempt == 2L)
    h <- if (is.null(token)) {
      headers
    } else {
      c(headers, Authorization = paste("Bearer", token))
    }
    token <- NULL
    perform <- if (method == "HEAD") zuhttp::zu_head else zuhttp::zu_get
    resp <- tryCatch(
      perform(
        url,
        query = query,
        headers = h,
        check = FALSE,
        decode = FALSE,
        max_body = Inf,
        timeout = azure_timeout,
        client = azure_client()
      ),
      zu_error = function(e) {
        zulake_abort(
          "storage",
          sprintf(
            "cannot reach Azure for %s: %s",
            format_string(path),
            conditionMessage(e)
          ),
          path = path,
          reason = class(e)[1L]
        )
      }
    )
    h <- NULL
    if (
      zuhttp::zu_resp_status(resp) != 401L ||
        is.null(credential_entry(loc$handle)$fn)
    ) {
      break
    }
  }
  resp
}

# A classed error for a response that is not what `what` needed: 401 and
# 403 are zulake_error_auth, others zulake_error_storage. Fields `path`,
# `status` and `code` (the x-ms-error-code header, or NA).
azure_fail <- function(resp, what, path) {
  status <- zuhttp::zu_resp_status(resp)
  code <- zuhttp::zu_resp_header(resp, "x-ms-error-code")
  code <- if (length(code)) code[1L] else NA_character_
  kind <- if (status %in% c(401L, 403L)) "auth" else "storage"
  zulake_abort(
    kind,
    sprintf(
      "cannot %s %s: Azure answered HTTP %s%s.",
      what,
      format_string(path),
      format_number(status),
      if (is.na(code)) "" else sprintf(" (%s)", format_string(code))
    ),
    path = path,
    status = status,
    code = code
  )
}

# ---- the backend ---------------------------------------------------------

# The Azure backend for a parsed URI (parse_azure_uri()) and a credential
# handle. Its functions hold the location and the handle, nothing else.
storage_azure <- function(parts, handle) {
  # Values, not the argument promises, whose code holds the caller's srcrefs.
  parts <- parts
  handle <- handle
  loc <- list(
    account = parts$account,
    container = parts$container,
    path = parts$path,
    endpoint = azure_endpoint(parts$account),
    handle = handle
  )
  blob <- function(path) {
    if (nzchar(loc$path)) paste0(loc$path, "/", path) else path
  }

  list_files <- function(prefix, after = NULL) {
    if (!is.null(after)) {
      check_string(after, "after")
    }
    full <- blob(prefix)
    pages <- list()
    marker <- NULL
    seen <- character()
    repeat {
      query <- list(
        restype = "container",
        comp = "list",
        prefix = full,
        delimiter = "/",
        include = "metadata"
      )
      if (!is.null(marker)) {
        query$marker <- marker
      }
      resp <- azure_request(loc, "GET", "", query = query, path = prefix)
      status <- zuhttp::zu_resp_status(resp)
      # No container lists nothing, as a missing directory does; but a
      # container gone after the first page would list part of the log (#46).
      if (
        status == 404L &&
          is.null(marker) &&
          identical(
            zuhttp::zu_resp_header(resp, "x-ms-error-code"),
            "ContainerNotFound"
          )
      ) {
        break
      }
      if (status != 200L) {
        azure_fail(resp, "list", prefix)
      }
      page <- parse_blob_list(zuhttp::zu_resp_raw(resp), prefix)
      pages[[length(pages) + 1L]] <- page$blobs
      if (is.na(page$next_marker)) {
        break
      }
      # Any marker seen before, not only the last one, would loop (#45).
      if (page$next_marker %in% seen) {
        zulake_abort(
          "storage",
          sprintf(
            "Azure returned the same listing marker twice for %s.",
            format_string(prefix)
          ),
          path = prefix
        )
      }
      marker <- page$next_marker
      seen <- c(seen, marker)
    }
    blob_names <- unlist(
      lapply(pages, function(p) p$name),
      use.names = FALSE
    ) %||%
      character()
    size <- unlist(lapply(pages, function(p) p$size), use.names = FALSE) %||%
      numeric()
    mtime <- unlist(
      lapply(pages, function(p) p$modification_time),
      use.names = FALSE
    ) %||%
      numeric()
    rel <- substr(blob_names, nchar(full) + 1L, nchar(blob_names))
    keep <- startsWith(blob_names, full) &
      nzchar(rel) &
      !grepl("/", rel, fixed = TRUE)
    if (!is.null(after)) {
      keep <- keep & sorts_after(rel, after)
    }
    rel <- rel[keep]
    ord <- order(rel, method = "radix")
    new_data_frame(list(
      name = rel[ord],
      size = as.numeric(size[keep][ord]),
      modification_time = as_utc(.POSIXct(
        as.numeric(mtime[keep][ord]),
        tz = "UTC"
      ))
    ))
  }

  get <- function(path) {
    resp <- azure_request(loc, "GET", blob(path), path = path)
    status <- zuhttp::zu_resp_status(resp)
    if (status == 404L) {
      abort_no_file(path, status = status)
    }
    if (status != 200L) {
      azure_fail(resp, "read", path)
    }
    zuhttp::zu_resp_raw(resp)
  }

  get_range <- function(path, from, to) {
    if (
      !(is_whole(from) &&
        is_whole(to) &&
        from >= 0 &&
        to >= from &&
        to <= max_exact)
    ) {
      zulake_abort(
        "storage",
        sprintf(
          "cannot read bytes %s to %s of %s.",
          format_number(from),
          format_number(to),
          format_string(path)
        ),
        path = path
      )
    }
    resp <- azure_request(
      loc,
      "GET",
      blob(path),
      range = c(from, to),
      path = path
    )
    status <- zuhttp::zu_resp_status(resp)
    if (status == 404L) {
      abort_no_file(path, status = status)
    }
    total <- content_range_total(zuhttp::zu_resp_header(resp, "content-range"))
    body <- if (status == 206L) zuhttp::zu_resp_raw(resp) else raw()
    if (status == 416L || (status == 206L && length(body) != to - from + 1)) {
      zulake_abort(
        "storage",
        sprintf(
          "cannot read bytes %s to %s of %s, which has %s.",
          format_number(from),
          format_number(to),
          format_string(path),
          if (is.na(total)) "fewer" else format_number(total)
        ),
        path = path
      )
    }
    if (status != 206L) {
      azure_fail(resp, "read", path)
    }
    body
  }

  head <- function(path) {
    resp <- azure_request(loc, "HEAD", blob(path), path = path)
    status <- zuhttp::zu_resp_status(resp)
    if (status == 404L) {
      return(NULL)
    }
    if (status != 200L) {
      azure_fail(resp, "find", path)
    }
    folder <- zuhttp::zu_resp_header(resp, "x-ms-meta-hdi_isfolder")
    if (length(folder) && tolower(folder[1L]) == "true") {
      return(NULL)
    }
    size <- byte_count(zuhttp::zu_resp_header(resp, "content-length")[1L])
    time <- parse_http_date(zuhttp::zu_resp_header(resp, "last-modified")[1L])
    if (is.na(size) || is.na(time)) {
      zulake_abort(
        "storage",
        sprintf(
          "Azure's properties of %s lack a size or a time.",
          format_string(path)
        ),
        path = path
      )
    }
    list(size = size, modification_time = as_utc(.POSIXct(time, tz = "UTC")))
  }

  # Every function of this frame without its srcref: in a package
  # installed with its source kept (covr, R_KEEP_PKG_SOURCE=yes), a srcref
  # reaches environments of the session, which serialize() then writes into
  # a saved snapshot, the caller's token included (seen on CI, Stage 6).
  for (name in c("blob", "list_files", "get", "get_range", "head")) {
    assign(
      name,
      utils::removeSource(base::get(
        name,
        envir = environment(),
        inherits = FALSE
      ))
    )
  }
  list(
    kind = "azure",
    root = parts$uri,
    list = list_files,
    get = get,
    get_range = get_range,
    head = head,
    location = loc
  )
}

# The backend and blob name that read an absolute Azure URI found in the
# log (an `add` path, a deletion vector's path), with the table's
# credentials; NULL for a local path in the log of a local table. A table's
# files stay on its own backend: an Azure URI in a local table's log, and a
# local path or file: URI in a remote table's, are a zulake_error_uri (#44).
# So does an Azure URI on another account or container than the table's,
# before any request: the log does not choose who receives the token (#76).
storage_for_absolute <- function(storage, path) {
  if (!identical(storage$kind, "azure") || !is_azure_uri(path)) {
    if (!identical(storage$kind, "local")) {
      zulake_abort(
        "uri",
        sprintf(
          paste(
            "%s is not a location of this table's storage: a remote table's files",
            "are not read from local disk."
          ),
          format_string(path)
        ),
        path = path
      )
    }
    return(NULL)
  }
  parts <- parse_azure_uri(path)
  own <- storage$location
  if (
    !identical(parts$account, own$account) ||
      !identical(parts$container, own$container)
  ) {
    zulake_abort(
      "uri",
      sprintf(
        paste(
          "%s is not in this table's account and container (%s, %s): zulake reads",
          "a table's files only there."
        ),
        format_string(path),
        format_string(own$account),
        format_string(own$container)
      ),
      path = path
    )
  }
  name <- parts$path
  parts$path <- ""
  list(storage = storage_azure(parts, storage$location$handle), rel = name)
}

# ---- responses -----------------------------------------------------------

# One page of a List Blobs answer (EnumerationResults): `blobs` (full names,
# sizes, modification times in seconds) and `next_marker` (NA on the last
# page). Directories of a hierarchical namespace, which carry the metadata
# hdi_isfolder=true, are left out, and so are BlobPrefix entries. A page
# that is not such a document is a zulake_error_storage.
parse_blob_list <- function(bytes, prefix) {
  bad <- function(why) {
    zulake_abort(
      "storage",
      sprintf(
        "Azure's listing of %s is not a blob list: %s.",
        format_string(prefix),
        why
      ),
      path = prefix
    )
  }
  if (any(bytes == as.raw(0L))) {
    bad("it holds a NUL byte")
  }
  text <- rawToChar(bytes)
  Encoding(text) <- "UTF-8"
  if (!validUTF8(text)) {
    bad("it is not UTF-8")
  }
  if (
    !grepl("<EnumerationResults[ >]", text) ||
      !grepl("</EnumerationResults>", text, fixed = TRUE)
  ) {
    bad("it has no EnumerationResults element")
  }
  # The Blobs element alone, so that a name cannot be taken for markup.
  blobs <- regmatches(
    text,
    regexpr("(?s)<Blobs>.*</Blobs>|<Blobs ?/>", text, perl = TRUE)
  )
  rest <- if (length(blobs)) {
    sub("(?s)<Blobs>.*</Blobs>|<Blobs ?/>", "", text, perl = TRUE)
  } else {
    text
  }
  marker <- xml_element(rest, "NextMarker")
  items <- if (length(blobs)) {
    regmatches(blobs, gregexpr("(?s)<Blob>.*?</Blob>", blobs, perl = TRUE))[[
      1L
    ]]
  } else {
    character()
  }
  n <- length(items)
  name <- character(n)
  size <- numeric(n)
  mtime <- numeric(n)
  keep <- rep(TRUE, n)
  for (i in seq_len(n)) {
    item <- items[i]
    encoded <- grepl("<Name Encoded=\"true\">", item, fixed = TRUE)
    nm <- xml_element(
      sub("<Name Encoded=\"(true|false)\">", "<Name>", item),
      "Name"
    )
    props <- xml_element(item, "Properties", decode = FALSE)
    if (is.na(nm) || !nzchar(nm) || is.na(props)) {
      bad("a Blob element lacks its Name or Properties")
    }
    name[i] <- if (encoded) percent_decode(nm, "storage") else nm
    size[i] <- byte_count(xml_element(props, "Content-Length"))
    mtime[i] <- parse_http_date(xml_element(props, "Last-Modified"))
    if (is.na(size[i]) || is.na(mtime[i])) {
      bad(sprintf("the Blob %s lacks a size or a time", format_string(name[i])))
    }
    meta <- xml_element(item, "Metadata", decode = FALSE)
    if (
      !is.na(meta) &&
        identical(tolower(xml_element(meta, "hdi_isfolder")), "true")
    ) {
      keep[i] <- FALSE
    }
  }
  list(
    blobs = list(
      name = unname(name[keep]),
      size = size[keep],
      modification_time = mtime[keep]
    ),
    next_marker = if (is.na(marker) || !nzchar(marker)) {
      NA_character_
    } else {
      marker
    }
  )
}

# The text of the first <tag> element of `x` (entities decoded unless
# `decode` is FALSE), "" for an empty one, NA when there is none.
xml_element <- function(x, tag, decode = TRUE) {
  if (grepl(sprintf("<%s ?/>", tag), x)) {
    open <- regexpr(sprintf("<%s>", tag), x, fixed = TRUE)
    empty <- regexpr(sprintf("<%s ?/>", tag), x)
    if (open < 0 || empty < open) {
      return("")
    }
  }
  m <- regmatches(
    x,
    regexec(sprintf("(?s)<%s>(.*?)</%s>", tag, tag), x, perl = TRUE)
  )[[1L]]
  if (!length(m)) {
    return(NA_character_)
  }
  if (decode) xml_decode(m[2L]) else m[2L]
}

# XML character and entity references decoded.
xml_decode <- function(x) {
  if (!grepl("&", x, fixed = TRUE)) {
    return(x)
  }
  m <- gregexpr("&(#[0-9]+|#x[0-9A-Fa-f]+|[A-Za-z]+);", x)
  refs <- regmatches(x, m)[[1L]]
  pieces <- regmatches(x, m, invert = TRUE)[[1L]]
  named <- c(amp = "&", lt = "<", gt = ">", quot = "\"", apos = "'")
  out <- vapply(
    refs,
    function(r) {
      body <- substr(r, 2L, nchar(r) - 1L)
      if (startsWith(body, "#")) {
        # A code point XML allows, or the reference left as it is.
        code <- if (startsWith(body, "#x")) {
          strtoi(substring(body, 3L), 16L)
        } else {
          suppressWarnings(as.numeric(substring(body, 2L)))
        }
        ok <- !is.na(code) &&
          code >= 1 &&
          code <= 0x10FFFF &&
          !(code >= 0xD800 && code <= 0xDFFF)
        if (ok) intToUtf8(code) else r
      } else if (body %in% names(named)) {
        named[[body]]
      } else {
        r
      }
    },
    "",
    USE.NAMES = FALSE
  )
  text <- paste0(pieces, c(out, ""), collapse = "")
  Encoding(text) <- "UTF-8"
  text
}

# Seconds since 1970 of an HTTP date in RFC 1123 form ("Thu, 26 Nov 2026
# 16:04:00 GMT"), read without the locale's month names; NA otherwise.
parse_http_date <- function(x) {
  if (!is_string(x)) {
    return(NA_real_)
  }
  m <- regmatches(
    x,
    regexec(
      "^[A-Za-z]{3}, ([0-9]{2}) ([A-Za-z]{3}) ([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT$",
      x
    )
  )[[1L]]
  if (!length(m)) {
    return(NA_real_)
  }
  months <- c(
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec"
  )
  mon <- match(m[3L], months)
  day <- as.integer(m[2L])
  if (is.na(mon)) {
    return(NA_real_)
  }
  date <- as.Date(sprintf("%s-%02d-%02d", m[4L], mon, day), format = "%Y-%m-%d")
  hms <- as.integer(m[5:7])
  if (
    is.na(date) ||
      as.integer(format(date, "%d")) != day ||
      hms[1L] > 23L ||
      hms[2L] > 59L ||
      hms[3L] > 60L
  ) {
    return(NA_real_)
  }
  as.numeric(date) * 86400 + hms[1L] * 3600 + hms[2L] * 60 + hms[3L]
}

# The total size in a Content-Range header ("bytes 0-9/100"), or NA.
content_range_total <- function(x) {
  if (!length(x) || !grepl("^bytes [0-9*-]+/[0-9]+$", x[1L])) {
    return(NA_real_)
  }
  byte_count(sub("^.*/", "", x[1L]))
}

# A number of bytes Azure sent as text (Content-Length, a range's total):
# decimal digits only, up to 2^53 - 1, compared as text so that nothing
# rounds; NA otherwise (#68). `as.numeric()` took "Inf", "0x10", "1e3",
# " 12 " and rounded 9007199254740993.
byte_count <- function(x) {
  if (!is_string(x) || !grepl("^[0-9]+$", x)) {
    return(NA_real_)
  }
  digits <- sub("^0+(?=.)", "", x, perl = TRUE)
  limit <- format_number(max_exact)
  if (
    nchar(digits) > nchar(limit) ||
      (nchar(digits) == nchar(limit) && sorts_after(digits, limit))
  ) {
    return(NA_real_)
  }
  as.numeric(digits)
}

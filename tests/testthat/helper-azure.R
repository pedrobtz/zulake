# Helpers for the Azure tests: the request fake (test-azure.R), the cassette
# router (test-azure.R, replaying what test-azure-emulator.R recorded), and
# Azurite (test-azure-emulator.R, tools/azurite/upload.R). Here, not in a
# test file, because the suite shuffles every top-level expression of a test
# file. tools/azurite/upload.R sources this file, so it uses nothing from
# testthat at file scope.

# ---- tokens ------------------------------------------------------------------

# Unsigned JWTs for Azurite's `--oauth basic`, which checks the audience, the
# issuer's form and the expiry, but not the signature (design D13). They are
# fixed, so cassettes recorded with them can be searched for them. None of
# them is a credential anywhere: Azurite is the only service that accepts
# the first, and it holds only the fixture tables.
#
#   aud https://storage.azure.com, iss https://sts.windows.net/<zero tenant>/,
#   exp 2100-01-01 (the good one), 2025-11-26 (expired), or aud
#   https://example.com (wrong audience).
azurite_token <- paste0(
  "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.",
  "eyJhdWQiOiJodHRwczovL3N0b3JhZ2UuYXp1cmUuY29tIiwiaXNzIjoiaHR0cHM6Ly9zdHMud2luZG93cy5uZXQvMDAwMDAwMDAtMDAw",
  "MC0wMDAwLTAwMDAtMDAwMDAwMDBhMmE3LyIsIm5iZiI6MTc2NDExNTIwMCwiaWF0IjoxNzY0MTE1MjAwLCJleHAiOjQxMDI0NDQ4MDAs",
  "Im9pZCI6Inp1bGFrZS10ZXN0In0.",
  "enVsYWtlLWF6dXJpdGUtdGVzdC10b2tlbi1ub3QtYS1zaWduYXR1cmU"
)
azurite_token_expired <- paste0(
  "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.",
  "eyJhdWQiOiJodHRwczovL3N0b3JhZ2UuYXp1cmUuY29tIiwiaXNzIjoiaHR0cHM6Ly9zdHMud2luZG93cy5uZXQvMDAwMDAwMDAtMDAw",
  "MC0wMDAwLTAwMDAtMDAwMDAwMDBhMmE3LyIsIm5iZiI6MTc2NDExNTIwMCwiaWF0IjoxNzY0MTE1MjAwLCJleHAiOjE3NjQxMTg4MDAs",
  "Im9pZCI6Inp1bGFrZS10ZXN0In0.",
  "enVsYWtlLWF6dXJpdGUtZXhwaXJlZC10b2tlbg"
)
azurite_token_wrong_audience <- paste0(
  "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.",
  "eyJhdWQiOiJodHRwczovL2V4YW1wbGUuY29tIiwiaXNzIjoiaHR0cHM6Ly9zdHMud2luZG93cy5uZXQvMDAwMDAwMDAtMDAwMC0wMDAw",
  "LTAwMDAtMDAwMDAwMDBhMmE3LyIsIm5iZiI6MTc2NDExNTIwMCwiaWF0IjoxNzY0MTE1MjAwLCJleHAiOjQxMDI0NDQ4MDAsIm9pZCI6",
  "Inp1bGFrZS10ZXN0In0.",
  "enVsYWtlLWF6dXJpdGUtd3JvbmctYXVkaWVuY2U"
)

# The pieces of a token a leak would show, however it was cut: the whole
# token, each of its three parts, and the bearer header value.
token_pieces <- function(token) {
  c(token, strsplit(token, ".", fixed = TRUE)[[1L]], paste("Bearer", token))
}

# ---- Azurite -------------------------------------------------------------------

# The test-azure-emulator.R environment, set by .github/workflows/azure-emulator.yaml
# (and by hand, tools/azurite/README.md):
#   ZULAKE_AZURITE_ENDPOINT  Azurite's blob endpoint with the account, e.g.
#                            https://127.0.0.1:10000/devstoreaccount1
#   ZULAKE_AZURITE_CA        the PEM file of the CA that signed its certificate
#   ZULAKE_AZURITE_ANSWERS   deltalake's answers for the same containers
#                            (tools/oracle/azurite.py)
#   ZULAKE_RECORD_CASSETTES  optional: a directory to record cassettes into
azurite_endpoint <- function() Sys.getenv("ZULAKE_AZURITE_ENDPOINT")

azurite_container <- "fixtures"
azurite_account <- "devstoreaccount1"

# A zuhttp client that trusts Azurite's certificate and returns every status.
azurite_client <- function(transport = NULL) {
  tls <- zuhttp::zu_tls(ca_extra = Sys.getenv("ZULAKE_AZURITE_CA"))
  if (is.null(transport)) {
    zuhttp::zu_client(tls = tls, check = FALSE)
  } else {
    zuhttp::zu_client(tls = tls, check = FALSE, transport = transport)
  }
}

# Percent-encodes a blob name for a URL path, byte by byte, keeping only
# RFC 3986's unreserved characters and "/". Written apart from zulake's own
# encoder, so that the two check each other. (utils::URLencode() leaves "%"
# as it is, which turns a file named "a%20b" into the blob "a b".)
blob_url_path <- function(name) {
  bytes <- charToRaw(enc2utf8(name))
  chars <- rawToChar(bytes, multiple = TRUE)
  keep <- bytes %in% charToRaw("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
  paste0(ifelse(keep, chars, paste0("%", toupper(as.character(bytes)))), collapse = "")
}

# Uploads every file under `dir` to `container` (created if needed), each as
# the blob `<prefix>/<path relative to dir>`, with the token above.
azurite_upload <- function(dir, container, prefix, endpoint = azurite_endpoint(), client = azurite_client()) {
  headers <- c(Authorization = paste("Bearer", azurite_token), `x-ms-version` = "2023-11-03")
  r <- zuhttp::zu_put(paste0(endpoint, "/", container), query = list(restype = "container"),
                      headers = headers, client = client)
  if (!zuhttp::zu_resp_status(r) %in% c(201L, 409L)) {
    stop("cannot create container ", container, ": HTTP ", zuhttp::zu_resp_status(r), call. = FALSE)
  }
  files <- list.files(dir, recursive = TRUE, all.files = TRUE, no.. = TRUE)
  for (f in files) {
    name <- paste0(prefix, "/", f)
    r <- zuhttp::zu_put(
      paste0(endpoint, "/", container, "/", blob_url_path(name)),
      headers = c(headers, `x-ms-blob-type` = "BlockBlob"),
      body = readBin(file.path(dir, f), "raw", file.size(file.path(dir, f))),
      client = client
    )
    if (zuhttp::zu_resp_status(r) != 201L) {
      stop("cannot upload ", name, ": HTTP ", zuhttp::zu_resp_status(r), call. = FALSE)
    }
  }
  invisible(length(files))
}

# The URI of a fixture table uploaded to Azurite, in one of the three forms.
azurite_uri <- function(table, form = "abfss") {
  switch(form,
    abfss = sprintf("abfss://%s@%s.dfs.core.windows.net/%s", azurite_container, azurite_account, table),
    dfs = sprintf("https://%s.dfs.core.windows.net/%s/%s", azurite_account, azurite_container, table),
    blob = sprintf("https://%s.blob.core.windows.net/%s/%s", azurite_account, azurite_container, table)
  )
}

local_azurite <- function(env = parent.frame()) {
  testthat::skip_if(!nzchar(azurite_endpoint()), "Azurite is not set up (ZULAKE_AZURITE_ENDPOINT)")
  withr::local_options(
    zulake.azure_endpoint = azurite_endpoint(), zulake.azure_client = azurite_client(),
    .local_envir = env
  )
}

# What zulake says about a snapshot, minus what depends on where the table
# is: the `uri` columns (the root differs), and the log's file times and the
# commit times taken from them (Azurite gives each blob its upload time).
snapshot_answers <- function(tbl) {
  files <- suppressWarnings(lake_files(tbl))
  files$uri <- NULL
  log <- lake_log(tbl)
  log$modification_time <- NULL
  dv <- if (requireNamespace("zuroar", quietly = TRUE)) lake_deletion_vectors(tbl) else lake_deletion_vectors(tbl, rows = FALSE)
  dv$uri <- NULL
  history <- lake_history(tbl)
  history$timestamp <- NULL
  list(
    version = lake_version(tbl), schema = lake_schema(tbl), protocol = lake_protocol(tbl),
    metadata = lake_metadata(tbl), properties = lake_properties(tbl), files = files,
    removed = lake_removed(tbl), transactions = lake_transactions(tbl), domains = lake_domains(tbl),
    history = history, log = log, versions = lake_versions(tbl)$version,
    count = suppressWarnings(lake_count(tbl)), deletion_vectors = dv,
    read = if (requireNamespace("zuroar", quietly = TRUE) || !nrow(dv)) collect_warnings(lake_read(tbl))
  )
}

open_or_class <- function(uri, version, credentials = NULL) {
  tryCatch(lake_open(uri, version = version, credentials = credentials), zulake_error = function(e) class(e)[1L])
}

# The session cassette_tables are recorded and replayed with: open, files,
# read and deletion vectors of the latest version, with the session's
# download cache empty, so that every data file is requested.
cassette_session <- function(table) {
  local_empty_download_cache()
  tbl <- lake_open(azurite_uri(table), credentials = function() azurite_token)
  dv_ok <- requireNamespace("zuroar", quietly = TRUE)
  files <- suppressWarnings(lake_files(tbl))
  files$uri <- NULL
  list(
    version = lake_version(tbl),
    files = files,
    read = if (dv_ok || all(tbl$files$deletion_vector_id == "")) lake_read(tbl),
    rows = if (dv_ok) lake_deletion_vectors(tbl)$rows
  )
}

# zulake's per-session download cache (read.R) empty until `env` ends.
local_empty_download_cache <- function(env = parent.frame()) {
  cache <- get("cache_env", envir = asNamespace("zulake"))
  old <- cache$files
  cache$files <- NULL
  withr::defer(cache$files <- old, envir = env)
}

# Expect no piece of `token` (token_pieces()) in `x`: in its serialization,
# which reaches every field of a condition, a snapshot or a cassette's
# interactions, and in what it prints.
expect_no_token <- function(x, token, label = NULL) {
  bytes <- serialize(x, NULL)
  text <- paste(utils::capture.output(print(x)), collapse = "\n")
  if (inherits(x, "condition")) text <- paste(text, conditionMessage(x))
  for (p in token_pieces(token)) {
    found <- length(grepRaw(p, bytes, fixed = TRUE)) > 0L
    where <- if (found) paste0(" (at ", token_path(x, p), "; environments serialized: ", serialized_envs(x), ")") else ""
    testthat::expect_false(found,
                           label = paste0(label %||% "the serialization", " holds the token piece ", substr(p, 1, 12), where))
    testthat::expect_false(grepl(p, text, fixed = TRUE),
                           label = paste(label %||% "the printed form", "holds the token piece", substr(p, 1, 12)))
  }
  invisible(x)
}

# The bindings of every environment serialize() writes for `x`, promise
# environments included, for a failure message.
serialized_envs <- function(x) {
  envs <- list()
  serialize(x, NULL, refhook = function(e) {
    if (is.environment(e)) envs[[length(envs) + 1L]] <<- paste(utils::head(ls(e, all.names = TRUE), 8), collapse = ",")
    NULL
  })
  paste(unique(unlist(envs)), collapse = " | ")
}

# Where in `x` the string `piece` is, for a failure message: a path of
# names, environments shown by their bindings, attributes as @name.
token_path <- function(x, piece) {
  seen <- new.env()
  walk <- function(v, path, depth) {
    if (depth > 40L) return(NULL)
    if (is.character(v)) {
      return(if (any(grepl(piece, v, fixed = TRUE))) path)
    }
    if (is.environment(v)) {
      if (isNamespace(v) || identical(v, globalenv()) || identical(v, emptyenv()) || identical(v, baseenv())) return(NULL)
      key <- format(v)
      if (!is.null(seen[[key]])) return(NULL)
      seen[[key]] <- TRUE
      for (nm in ls(v, all.names = TRUE)) {
        b <- if (bindingIsActive(nm, v)) NULL else get(nm, envir = v, inherits = FALSE)
        hit <- walk(b, paste0(path, "$<env>", nm), depth + 1L)
        if (!is.null(hit)) return(hit)
      }
      return(walk(parent.env(v), paste0(path, "$<parent>"), depth + 1L))
    }
    if (is.function(v)) {
      hit <- walk(environment(v), paste0(path, "<closure env>"), depth + 1L)
      if (!is.null(hit)) return(hit)
    }
    if (is.list(v) || is.pairlist(v)) {
      nms <- names(v) %||% rep("", length(v))
      for (i in seq_along(v)) {
        hit <- walk(v[[i]], paste0(path, "$", if (nzchar(nms[i])) nms[i] else i), depth + 1L)
        if (!is.null(hit)) return(hit)
      }
    }
    for (a in setdiff(names(attributes(v)), c("names", "class", "row.names"))) {
      hit <- walk(attr(v, a, exact = TRUE), paste0(path, "@", a), depth + 1L)
      if (!is.null(hit)) return(hit)
    }
    NULL
  }
  walk(x, "x", 0L) %||% "not found by walking"
}

# ---- the request fake ------------------------------------------------------------

# An HTTP date as Azure writes one, in English whatever the locale.
http_date <- function(time) {
  lt <- as.POSIXlt(time, tz = "UTC")
  days <- c("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")
  months <- c("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
  sprintf("%s, %02d %s %04d %02d:%02d:%02d GMT", days[lt$wday + 1L], lt$mday, months[lt$mon + 1L],
          lt$year + 1900L, lt$hour, lt$min, as.integer(lt$sec))
}

xml_escape <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  gsub("\"", "&quot;", x, fixed = TRUE)
}

# Percent-decoding, written apart from zulake's.
url_decode <- function(x) {
  vapply(x, function(s) {
    bytes <- charToRaw(s)
    out <- raw()
    i <- 1L
    while (i <= length(bytes)) {
      if (bytes[i] == as.raw(0x25) && i + 2L <= length(bytes)) {
        out <- c(out, as.raw(strtoi(rawToChar(bytes[(i + 1L):(i + 2L)]), 16L)))
        i <- i + 3L
      } else {
        out <- c(out, bytes[i])
        i <- i + 1L
      }
    }
    txt <- rawToChar(out)
    Encoding(txt) <- "UTF-8"
    txt
  }, "", USE.NAMES = FALSE)
}

# A Blob service that serves the files under `root` as the blobs of the
# container `container` of every account, and records every request in
# `log` (an environment; `log$requests` is a list of method, url, host,
# path (the decoded blob path after the container), query (named list,
# decoded), headers (named, lower-case names) and timeout (the seconds
# zuhttp was given)).
#
#   page_size  blobs per List Blobs page; NextMarker is opaque ("page-<n>")
#   auth       function(authorization header or NULL) returning NULL to
#              serve, or a status to answer with (401, 403)
#   override   function(request record) returning a zu_response to send
#              instead, or NULL
azure_fake <- function(root, log, container = "lake", page_size = 1000L, auth = NULL, override = NULL) {
  log$requests <- list()
  zuhttp::zu_mock_transport(function(req) {
    url <- req$url
    m <- regmatches(url, regexec("^https://([^/]+)(/[^?]*)?(?:[?](.*))?$", url, perl = TRUE))[[1L]]
    host <- m[2L]
    raw_path <- sub("^/", "", m[3L])
    query <- list()
    if (nzchar(m[4L])) {
      for (kv in strsplit(m[4L], "&", fixed = TRUE)[[1L]]) {
        kv <- strsplit(kv, "=", fixed = TRUE)[[1L]]
        query[[url_decode(kv[1L])]] <- url_decode(if (length(kv) > 1L) paste(kv[-1L], collapse = "=") else "")
      }
    }
    headers <- req$headers
    names(headers) <- tolower(names(headers))
    segments <- strsplit(raw_path, "/", fixed = TRUE)[[1L]]
    # Path-style, as Azurite's: the account is the first segment.
    if (!grepl("[.]blob[.]core[.]windows[.]net$", host)) {
      host <- paste0(host, "/", segments[1L])
      segments <- segments[-1L]
    }
    rec <- list(
      method = req$method, url = url, host = host,
      container = url_decode(segments[1L]),
      path = paste(url_decode(segments[-1L]), collapse = "/"),
      query = query, headers = as.list(headers), timeout = req$policy$timeout
    )
    log$requests[[length(log$requests) + 1L]] <- rec
    if (is.function(override)) {
      out <- override(rec)
      if (!is.null(out)) return(out)
    }
    if (is.function(auth)) {
      status <- auth(rec$headers$authorization)
      if (!is.null(status)) {
        code <- if (status == 401L) "InvalidAuthenticationInfo" else "AuthorizationPermissionMismatch"
        return(zuhttp::zu_response(status, c(`x-ms-error-code` = code)))
      }
    }
    if (!identical(rec$container, container)) {
      return(zuhttp::zu_response(404L, c(`x-ms-error-code` = "ContainerNotFound")))
    }
    if (identical(query$comp, "list")) {
      return(fake_list(root, query, page_size))
    }
    file <- file.path(root, rec$path)
    if (!nzchar(rec$path) || !file.exists(file) || dir.exists(file)) {
      return(zuhttp::zu_response(404L, c(`x-ms-error-code` = "BlobNotFound")))
    }
    size <- file.size(file)
    props <- c(`Content-Length` = format(size, scientific = FALSE), `Last-Modified` = http_date(file.mtime(file)))
    if (req$method == "HEAD") {
      return(zuhttp::zu_response(200L, props))
    }
    bytes <- readBin(file, "raw", size)
    range <- rec$headers$range
    if (is.null(range)) {
      return(zuhttp::zu_response(200L, props, bytes))
    }
    r <- as.numeric(strsplit(sub("^bytes=", "", range), "-", fixed = TRUE)[[1L]])
    if (r[1L] >= size) {
      return(zuhttp::zu_response(416L, c(`x-ms-error-code` = "InvalidRange", `Content-Range` = paste0("bytes */", size))))
    }
    to <- min(r[2L], size - 1)
    zuhttp::zu_response(
      206L,
      c(`Content-Range` = sprintf("bytes %.0f-%.0f/%.0f", r[1L], to, size)),
      bytes[seq(r[1L] + 1, to + 1)]
    )
  })
}

# One List Blobs page over the files under `root`.
fake_list <- function(root, query, page_size) {
  prefix <- query$prefix %||% ""
  files <- list.files(root, recursive = TRUE, all.files = TRUE)
  files <- files[startsWith(files, prefix)]
  rest <- substr(files, nchar(prefix) + 1L, nchar(files))
  entries <- if (identical(query$delimiter, "/")) {
    unique(ifelse(grepl("/", rest, fixed = TRUE), paste0(prefix, sub("/.*$", "/", rest)), files))
  } else {
    files
  }
  entries <- entries[order(entries, method = "radix")]
  start <- if (is.null(query$marker)) 0L else as.integer(sub("^page-", "", query$marker))
  page <- entries[seq_along(entries) > start & seq_along(entries) <= start + page_size]
  more <- start + page_size < length(entries)
  items <- vapply(page, function(e) {
    if (endsWith(e, "/")) {
      return(sprintf("<BlobPrefix><Name>%s</Name></BlobPrefix>", xml_escape(e)))
    }
    f <- file.path(root, e)
    sprintf(
      paste0("<Blob><Name>%s</Name><Properties><Last-Modified>%s</Last-Modified>",
             "<Etag>0x1</Etag><Content-Length>%s</Content-Length><BlobType>BlockBlob</BlobType>",
             "</Properties><Metadata /></Blob>"),
      xml_escape(e), http_date(file.mtime(f)), format(file.size(f), scientific = FALSE)
    )
  }, "")
  body <- paste0(
    "<?xml version=\"1.0\" encoding=\"utf-8\"?><EnumerationResults ServiceEndpoint=\"https://x/\" ",
    "ContainerName=\"c\"><Prefix>", xml_escape(prefix), "</Prefix>",
    if (!is.null(query$marker)) paste0("<Marker>", query$marker, "</Marker>"),
    "<Delimiter>/</Delimiter><Blobs>", paste(items, collapse = ""), "</Blobs>",
    if (more) sprintf("<NextMarker>page-%d</NextMarker>", start + page_size) else "<NextMarker />",
    "</EnumerationResults>"
  )
  zuhttp::zu_response(200L, c(`Content-Type` = "application/xml"), charToRaw(enc2utf8(body)))
}

# The fake's URI for a fixture table, in one of the three forms, account
# "acct" and container "lake".
fake_uri <- function(table, form = "abfss") {
  switch(form,
    abfss = paste0("abfss://lake@acct.dfs.core.windows.net/", table),
    dfs = paste0("https://acct.dfs.core.windows.net/lake/", table),
    blob = paste0("https://acct.blob.core.windows.net/lake/", table)
  )
}

fake_root <- function() file.path(fixture_dir(), "tables")

# The requests `log` recorded as storage calls ("list _delta_log/", "get
# <path>", "get_range <path>", "head <path>", paths relative to `table`),
# as recording_storage() writes them.
fake_calls <- function(log, table) {
  strip <- function(x) substring(x, nchar(table) + 2L)
  vapply(log$requests, function(r) {
    if (identical(r$query$comp, "list")) {
      paste("list", strip(r$query$prefix))
    } else if (r$method == "HEAD") {
      paste("head", strip(r$path))
    } else if (!is.null(r$headers$range)) {
      paste("get_range", strip(r$path))
    } else {
      paste("get", strip(r$path))
    }
  }, "")
}

# A zuhttp client over `transport`, for option zulake.azure_client.
fake_client <- function(transport) zuhttp::zu_client(transport = transport)

# Options for a test that reaches the fake: its client, and no endpoint
# override, so that requests go to <account>.blob.core.windows.net.
local_azure_fake <- function(transport, env = parent.frame()) {
  withr::local_options(zulake.azure_client = fake_client(transport), zulake.azure_endpoint = NULL, .local_envir = env)
}

# The requests `log` recorded, as a data frame: method, path, and the query
# and headers each as text, for comparisons.
fake_requests <- function(log) {
  reqs <- log$requests
  data.frame(
    method = vapply(reqs, function(r) r$method, ""),
    path = vapply(reqs, function(r) r$path, ""),
    stringsAsFactors = FALSE
  )
}

# ---- cassettes ---------------------------------------------------------------------

# A transport that sends each request through the cassette `name` in `dir`,
# or, for a request with a Range header, through the cassette
# `<name>-range-<from>-<to>`: a cassette key ignores Range
# (pedrobtz/zuhttp#353), so two ranges of one blob need two cassettes.
# A recording cassette sends on through `transport` (the network when
# NULL), with `tls`.
cassette_router <- function(dir, name, mode, transport = NULL, tls = NULL) {
  zuhttp::zu_mock_transport(function(req) {
    headers <- req$headers
    range <- headers[tolower(names(headers)) == "range"]
    cassette <- if (length(range)) {
      paste0(name, "-range-", gsub("[^0-9]+", "-", sub("^bytes=", "", range[[1L]])))
    } else {
      name
    }
    cassette <- if (is.null(transport)) {
      zuhttp::zu_cassette_transport(dir, cassette, mode = mode)
    } else {
      zuhttp::zu_cassette_transport(dir, cassette, mode = mode, transport = transport)
    }
    zuhttp::zu_perform(req, client = zuhttp::zu_client(transport = cassette, check = FALSE, tls = tls))
  })
}

# The condition `expr` raises, which must be of class `class`. Not
# expect_error()'s value, which carries testthat's trace of the call.
catch_error <- function(expr, class) {
  e <- tryCatch(expr, error = function(e) e)
  testthat::expect_s3_class(e, class)
  e
}

cassette_dir <- function() testthat::test_path("fixtures", "cassettes")

# The tables whose open, read and deletion vectors test-azure-emulator.R
# records as cassettes and test-azure.R replays.
cassette_tables <- c("zl-basic", "zl-partitioned", "table-with-dv-small")

`%||%` <- function(x, y) if (is.null(x)) y else x

# ---- the live suite ------------------------------------------------------------------

# ZULAKE_AZURE_URI, or a skip when it or ZULAKE_AZURE_TOKEN is unset
# (test-azure-live.R).
live_uri <- function() {
  uri <- Sys.getenv("ZULAKE_AZURE_URI")
  testthat::skip_if(!nzchar(uri) || !nzchar(Sys.getenv("ZULAKE_AZURE_TOKEN")),
                    "no live Azure table (ZULAKE_AZURE_URI and ZULAKE_AZURE_TOKEN)")
  uri
}

# The other two URI forms of an Azure URI.
live_uri_forms <- function(uri) {
  p <- parse_azure_uri(uri)
  path <- if (nzchar(p$path)) paste0("/", p$path) else ""
  forms <- c(
    sprintf("abfss://%s@%s.dfs.core.windows.net%s", p$container, p$account, path),
    sprintf("https://%s.dfs.core.windows.net/%s%s", p$account, p$container, path),
    sprintf("https://%s.blob.core.windows.net/%s%s", p$account, p$container, path)
  )
  setdiff(forms, sub("/+$", "", uri))
}

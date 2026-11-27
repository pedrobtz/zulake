# The Azure backend (design section 4.1, D3, D4): the requests a
# zu_mock_transport() fake recorded (method, path, query, Range,
# Authorization, x-ms-version), List Blobs pagination, the 401 retry, the
# three URI forms and the refusals, the List Blobs parser, the token's
# absence from everything a user can see or save, and the cassettes
# recorded from Azurite (test-azure-emulator.R), replayed.

test_that("an Azure table makes the same storage calls as a local one, as the fake received them", {
  for (table in c("zl-basic", "zl-partitioned", "table-with-dv-small", "v2-classic-checkpoint-json")) {
    if (table == "table-with-dv-small" && !requireNamespace("zuroar", quietly = TRUE)) next
    local_empty_download_cache()
    env <- new.env()
    storage <- remote_storage(storage_local(fixture_table(table)), env)
    want <- lake_read(snapshot_build(storage, fixture_table(table)))
    want_calls <- env$calls

    local_empty_download_cache()
    log <- new.env()
    local_azure_fake(azure_fake(fake_root(), log))
    got <- lake_read(lake_open(fake_uri(table), credentials = function() "tok-1"))
    expect_identical(got, want, label = table)
    expect_identical(fake_calls(log, table), want_calls, label = table)
    for (r in log$requests) {
      expect_identical(r$host, "acct.blob.core.windows.net")
      expect_identical(r$container, "lake")
      expect_identical(r$headers[["x-ms-version"]], "2023-11-03")
      expect_identical(r$headers$authorization, "Bearer tok-1")
      expect_true(r$method %in% c("GET", "HEAD"))
      # azure_timeout, as zuhttp received it: zuhttp enforces it.
      expect_identical(r$timeout, 600)
    }
    # A blob path is percent-encoded byte by byte, and decodes to the file's
    # own name ("p_str=a%20b" is a directory of that name, from the log's
    # "p_str=a%2520b").
    gets <- Filter(function(r) r$method == "GET" && is.null(r$query$comp), log$requests)
    for (r in gets) {
      expect_true(file.exists(file.path(fake_root(), r$path)), label = r$path)
      expect_identical(sub("^https://[^/]+/lake/", "", sub("[?].*$", "", r$url)), blob_url_path(r$path))
      expect_length(r$query, 0L)
    }
  }
})

test_that("List Blobs asks for one directory and follows NextMarker to the last page", {
  table <- "simple_table"
  for (page in c(1L, 2L, 3L, 1000L)) {
    log <- new.env()
    local_azure_fake(azure_fake(fake_root(), log, page_size = page))
    storage <- storage_for(fake_uri(table), function() "tok")
    got <- storage$list("_delta_log/")
    want <- storage_local(fixture_table(table))$list("_delta_log/")
    expect_identical(got$name, want$name)
    expect_identical(got$size, want$size)
    expect_identical(as.numeric(got$modification_time), floor(as.numeric(want$modification_time)))
    lists <- log$requests
    # _delta_log/ holds five commits and the .tmp/ directory, which is a
    # BlobPrefix and not a file.
    expect_length(lists, ceiling(6 / page))
    for (k in seq_along(lists)) {
      q <- lists[[k]]$query
      expect_identical(q[c("restype", "comp", "prefix", "delimiter", "include")],
                       list(restype = "container", comp = "list", prefix = "simple_table/_delta_log/",
                            delimiter = "/", include = "metadata"))
      expect_identical(q$marker, if (k == 1L) NULL else sprintf("page-%d", (k - 1L) * page))
      expect_identical(lists[[k]]$path, "")
    }
  }
  # `after` filters the listing, in byte order.
  log <- new.env()
  local_azure_fake(azure_fake(fake_root(), log, page_size = 2L))
  storage <- storage_for(fake_uri(table), function() "tok")
  expect_identical(storage$list("_delta_log/", after = "00000000000000000002.json")$name,
                   c("00000000000000000003.json", "00000000000000000004.json"))
  expect_error(storage$list("_delta_log/", after = NA_character_), class = "zulake_error_argument")
})

test_that("a listing marker that comes back unchanged is an error, not a loop", {
  log <- new.env()
  body <- paste0(
    "<?xml version=\"1.0\" encoding=\"utf-8\"?><EnumerationResults><Blobs></Blobs>",
    "<NextMarker>again</NextMarker></EnumerationResults>"
  )
  local_azure_fake(azure_fake(fake_root(), log, override = function(r) zuhttp::zu_response(200L, body = body)))
  storage <- storage_for(fake_uri("zl-basic"), function() "tok")
  expect_error(storage$list("_delta_log/"), class = "zulake_error_storage")
  expect_length(log$requests, 2L)
})

test_that("get_range() sends Range for the bytes it asks for, and refuses what Azure cannot give", {
  log <- new.env()
  local_azure_fake(azure_fake(fake_root(), log))
  storage <- storage_for(fake_uri("zl-basic"), function() "tok")
  local <- storage_local(fixture_table("zl-basic"))
  name <- "_delta_log/00000000000000000000.json"
  size <- local$head(name)$size
  for (r in list(c(0, 0), c(0, size - 1), c(5, 17), c(size - 1, size - 1))) {
    expect_identical(storage$get_range(name, r[1L], r[2L]), local$get_range(name, r[1L], r[2L]))
    expect_identical(log$requests[[length(log$requests)]]$headers$range, sprintf("bytes=%.0f-%.0f", r[1L], r[2L]))
  }
  # One past the end: the fake (as Azure) gives the bytes there are, which
  # are too few; at the end, 416.
  e <- expect_error(storage$get_range(name, size - 2, size), class = "zulake_error_storage")
  expect_match(conditionMessage(e), sprintf("which has %.0f", size), fixed = TRUE)
  expect_error(local$get_range(name, size - 2, size), class = "zulake_error_storage")
  expect_error(storage$get_range(name, size, size), class = "zulake_error_storage")
  n <- length(log$requests)
  for (bad in list(c(-1, 0), c(3, 2), c(0.5, 1), c(NA, 1), c(0, Inf), c(0, 2^53))) {
    expect_error(storage$get_range(name, bad[1L], bad[2L]), class = "zulake_error_storage")
  }
  expect_length(log$requests, n)
  # A range ends at 2^53 - 1 at most: 2^53 - 2 and 2^53 - 1 go to Azure,
  # which has too few bytes; 2^53 (above) does not.
  for (to in c(2^53 - 2, 2^53 - 1)) {
    e <- expect_error(storage$get_range(name, 0, to), class = "zulake_error_storage")
    expect_match(conditionMessage(e), sprintf("which has %.0f", size), fixed = TRUE)
    expect_identical(log$requests[[length(log$requests)]]$headers$range, sprintf("bytes=0-%.0f", to))
  }
  expect_length(log$requests, n + 2L)
  expect_error(storage$get_range("_delta_log/nope.json", 0, 1), class = "zulake_error_storage")
})

test_that("head() gives size and time, NULL for a missing blob or a directory", {
  log <- new.env()
  local_azure_fake(azure_fake(fake_root(), log, override = function(r) {
    if (r$path == "zl-basic/dir") {
      zuhttp::zu_response(200L, c(`Content-Length` = "0", `Last-Modified` = "Thu, 26 Nov 2026 16:04:00 GMT",
                                  `x-ms-meta-hdi_isfolder` = "true"))
    }
  }))
  storage <- storage_for(fake_uri("zl-basic"), function() "tok")
  local <- storage_local(fixture_table("zl-basic"))
  name <- "_delta_log/00000000000000000001.json"
  got <- storage$head(name)
  want <- local$head(name)
  expect_identical(got$size, want$size)
  expect_identical(as.numeric(got$modification_time), floor(as.numeric(want$modification_time)))
  expect_s3_class(got$modification_time, "POSIXct")
  expect_null(storage$head("_delta_log/nope.json"))
  expect_null(storage$head("dir"))
  expect_identical(vapply(log$requests, function(r) r$method, ""), rep("HEAD", 3L))
  # Properties without a size or a time are not a file's.
  for (h in list(c(`Last-Modified` = "Thu, 26 Nov 2026 16:04:00 GMT"), c(`Content-Length` = "3"),
                 c(`Content-Length` = "3", `Last-Modified` = "yesterday"))) {
    local_azure_fake(azure_fake(fake_root(), new.env(), override = function(r) zuhttp::zu_response(200L, h)))
    expect_error(storage$head("x"), class = "zulake_error_storage")
  }
})

test_that("statuses Azure answers become classed errors with status and code", {
  status <- 500L
  local_azure_fake(azure_fake(fake_root(), new.env(), override = function(r) {
    zuhttp::zu_response(status, c(`x-ms-error-code` = "InternalError"))
  }))
  storage <- storage_for(fake_uri("zl-basic"), function() "tok")
  for (op in list(function() storage$list("_delta_log/"), function() storage$get("x"),
                  function() storage$get_range("x", 0, 1), function() storage$head("x"))) {
    status <- 500L
    e <- expect_error(op(), class = "zulake_error_storage")
    expect_identical(e$status, 500L)
    expect_identical(e$code, "InternalError")
    status <- 403L
    e <- expect_error(op(), class = "zulake_error_auth")
    expect_identical(e$status, 403L)
  }
  # A missing blob, and a missing container: nothing to list, no table.
  local_azure_fake(azure_fake(fake_root(), new.env()))
  e <- expect_error(storage_for(fake_uri("zl-basic"), NULL)$get("nope"), class = "zulake_error_storage")
  expect_identical(e$status, 404L)
  expect_false(lake_is_table("abfss://other@acct.dfs.core.windows.net/zl-basic"))
  expect_error(lake_open("abfss://other@acct.dfs.core.windows.net/zl-basic"), class = "zulake_error_not_table")
  expect_false(lake_is_table(fake_uri("no-such-table")))
  expect_true(lake_is_table(fake_uri("zl-basic")))
})

test_that("a transport failure is a zulake_error_storage that keeps zuhttp's message, not its request", {
  local_azure_fake(zuhttp::zu_mock_transport(function(req) {
    stop(zuhttp::zu_condition("zu_connect_error", "could not connect", url = req$url, request = req))
  }))
  e <- catch_error(lake_open(fake_uri("zl-basic"), credentials = function() "secret-token-xyz"),
                   "zulake_error_storage")
  expect_identical(e$reason, "zu_connect_error")
  expect_match(conditionMessage(e), "could not connect", fixed = TRUE)
  expect_no_token(e, "secret-token-xyz")
})

test_that("a 401 calls credentials() once more and retries with the new token", {
  calls <- 0
  credentials <- function() {
    calls <<- calls + 1
    paste0("tok-", calls)
  }
  # Always 401: credentials() exactly twice, then a classed error.
  log <- new.env()
  local_azure_fake(azure_fake(fake_root(), log, auth = function(h) 401L))
  e <- expect_error(lake_open(fake_uri("zl-basic"), credentials = credentials), class = "zulake_error_auth")
  expect_identical(calls, 2)
  expect_identical(e$status, 401L)
  expect_identical(e$code, "InvalidAuthenticationInfo")
  expect_identical(vapply(log$requests, function(r) r$headers$authorization, ""), c("Bearer tok-1", "Bearer tok-2"))

  # 401 for the first token only: one retry, then every later request has
  # the new token, and credentials() is not called again.
  calls <- 0
  log <- new.env()
  local_azure_fake(azure_fake(fake_root(), log, auth = function(h) if (identical(h, "Bearer tok-1")) 401L))
  tbl <- lake_open(fake_uri("zl-basic"), credentials = credentials)
  lake_read(tbl)
  lake_load(tbl)
  expect_identical(calls, 2)
  auth <- vapply(log$requests, function(r) r$headers$authorization, "")
  expect_identical(auth[1:2], c("Bearer tok-1", "Bearer tok-2"))
  expect_true(all(auth[-1L] == "Bearer tok-2"))

  # 403 is not retried.
  calls <- 0
  local_azure_fake(azure_fake(fake_root(), new.env(), auth = function(h) 403L))
  e <- expect_error(lake_open(fake_uri("zl-basic"), credentials = credentials), class = "zulake_error_auth")
  expect_identical(calls, 1)
  expect_identical(e$code, "AuthorizationPermissionMismatch")

  # Without credentials, no Authorization header and no retry.
  log <- new.env()
  local_azure_fake(azure_fake(fake_root(), log, auth = function(h) if (!is.null(h)) 401L))
  expect_s3_class(lake_open(fake_uri("zl-basic")), "zulake_table")
  expect_true(all(vapply(log$requests, function(r) is.null(r$headers$authorization), NA)))
  log <- new.env()
  local_azure_fake(azure_fake(fake_root(), log, auth = function(h) 401L))
  expect_error(lake_open(fake_uri("zl-basic")), class = "zulake_error_auth")
  expect_length(log$requests, 1L)
})

test_that("a credentials() that fails on a refresh leaves the snapshot usable once it works again", {
  state <- "ok"
  calls <- 0
  credentials <- function() {
    calls <<- calls + 1
    if (state == "fail") stop("expired login")
    paste0("tok-", calls)
  }
  accept <- "Bearer tok-1"
  log <- new.env()
  local_azure_fake(azure_fake(fake_root(), log, auth = function(h) if (!identical(h, accept)) 401L))
  tbl <- lake_open(fake_uri("zl-basic"), credentials = credentials)
  # Azure stops taking the token, and credentials() fails: a classed error.
  accept <- "none"
  state <- "fail"
  e <- expect_error(lake_load(tbl), class = "zulake_error_auth")
  expect_match(conditionMessage(e), "expired login", fixed = TRUE)
  expect_identical(calls, 2)
  # It works again: the next request refreshes once and goes on.
  state <- "ok"
  accept <- "Bearer tok-3"
  expect_identical(lake_version(lake_load(tbl)), lake_version(tbl))
  expect_identical(calls, 3)
  auth <- vapply(log$requests, function(r) r$headers$authorization, "")
  expect_identical(auth[length(auth)], "Bearer tok-3")
})

test_that("credentials() must return one token, and its failure is a classed error", {
  local_azure_fake(azure_fake(fake_root(), new.env()))
  for (bad in list(NA_character_, "", c("a", "b"), 1, NULL, "tok\nen", character())) {
    e <- expect_error(lake_open(fake_uri("zl-basic"), credentials = function() bad), class = "zulake_error_auth")
  }
  e <- expect_error(lake_open(fake_uri("zl-basic"), credentials = function() stop("no login")),
                    class = "zulake_error_auth")
  expect_match(conditionMessage(e), "no login", fixed = TRUE)
  expect_error(lake_open(fake_uri("zl-basic"), credentials = "tok"), class = "zulake_error_argument")
  # A leading "Bearer " is the header's, not the token's.
  log <- new.env()
  local_azure_fake(azure_fake(fake_root(), log))
  lake_open(fake_uri("zl-basic"), credentials = function() "Bearer tok")
  expect_identical(log$requests[[1L]]$headers$authorization, "Bearer tok")
})

test_that("the token is in no print, condition, field, serialized snapshot or cassette", {
  token <- paste0("eyJ0eXAiOiJKV1QifQ.", "c2VjcmV0LXRva2VuLXBheWxvYWQ", ".c2lnbmF0dXJlLWZvci16dWxha2U")
  # The closure holds the token as a value of its own environment, as a
  # user's `function() tok` does.
  credentials <- local({
    tok <- token
    function() tok
  })
  local_azure_fake(azure_fake(fake_root(), new.env(), auth = function(h) {
    if (!identical(h, paste("Bearer", token))) 401L
  }))
  tbl <- lake_open(fake_uri("table-with-dv-small"), credentials = credentials)
  # A saved snapshot writes two environments: its backend's frame and the
  # credential handle, whether or not the package keeps its source (with
  # it kept, srcrefs once reached the loader's environments and the
  # credential registry: CI, Stage 6).
  expect_identical(serialized_envs(tbl), "blob,get,get_range,handle,head,list_files,loc,name | id,root")
  expect_no_token(tbl, token, "the snapshot")
  expect_no_token(lake_load(tbl, version = 0), token, "a reloaded snapshot")
  expect_no_token(utils::capture.output(print(tbl), format(tbl), str(tbl)), token, "the print")
  outputs <- list(
    lake_files(tbl), lake_log(tbl), lake_history(tbl), lake_versions(tbl), lake_summary(tbl),
    lake_metadata(tbl), lake_protocol(tbl), lake_removed(tbl), lake_checkpoints(tbl)
  )
  if (requireNamespace("zuroar", quietly = TRUE)) {
    outputs <- c(outputs, list(lake_read(tbl), lake_deletion_vectors(tbl)))
  }
  expect_no_token(outputs, token, "the inspection frames")

  # Every condition the backend raises, each with every field.
  conditions <- list()
  catch <- function(expr) {
    conditions[[length(conditions) + 1L]] <<- tryCatch(expr, error = function(e) e)
  }
  storage <- tbl$storage
  catch(storage$get("nope"))
  catch(storage$get_range("_delta_log/00000000000000000000.json", 1e6, 1e6 + 1))
  catch(storage$get_range("_delta_log/00000000000000000000.json", -1, 0))
  status <- 401L
  local_azure_fake(azure_fake(fake_root(), new.env(), override = function(r) {
    zuhttp::zu_response(status, c(`x-ms-error-code` = "InvalidAuthenticationInfo"))
  }))
  catch(lake_load(tbl))
  status <- 403L
  catch(lake_open(fake_uri("zl-basic"), credentials = credentials))
  status <- 500L
  catch(storage$head("x"))
  local_azure_fake(zuhttp::zu_mock_transport(function(req) {
    stop(zuhttp::zu_condition("zu_tls_certificate_error", "certificate", url = req$url, request = req))
  }))
  catch(lake_open(fake_uri("zl-basic"), credentials = credentials))
  catch(lake_open(paste0(fake_uri("zl-basic"), "?sig=", token), credentials = credentials))
  catch(lake_open(sub("abfss://", paste0("abfss://", token, "@"), fake_uri("zl-basic"))))
  catch(lake_open(fake_uri("zl-basic"), credentials = function() c(token, token)))
  catch(lake_open(fake_uri("zl-basic"), credentials = function() paste0(token, "\n")))
  expect_length(conditions, 11L)
  for (e in conditions) {
    expect_s3_class(e, "zulake_error")
    expect_no_token(e, token, paste("a", class(e)[1L], "condition"))
  }

  # A cassette recorded with the token, through the router, holds none of
  # it, nor do the cassettes in the package.
  dir <- withr::local_tempdir()
  local_azure_fake(cassette_router(dir, "t", "record", transport = azure_fake(fake_root(), new.env())))
  lake_read(lake_open(fake_uri("zl-basic"), credentials = credentials))
  files <- list.files(dir, full.names = TRUE)
  expect_length(files, 1L)
  expect_no_token(readRDS(files), token, "a cassette recorded here")
  shipped <- list.files(cassette_dir(), pattern = "[.]rds$", full.names = TRUE)
  expect_gte(length(shipped), length(cassette_tables))
  for (f in shipped) expect_no_token(readRDS(f), azurite_token, basename(f))
})

test_that("a snapshot keeps no credentials: restored in another session it asks for lake_open()", {
  calls <- 0
  local_azure_fake(azure_fake(fake_root(), new.env()))
  tbl <- lake_open(fake_uri("zl-basic"), credentials = function() {
    calls <<- calls + 1
    "tok"
  })
  # In this session, an unserialized copy still reaches the credentials.
  copy <- unserialize(serialize(tbl, NULL))
  expect_identical(lake_version(lake_load(copy)), lake_version(tbl))
  # Another session has no entry for the handle.
  handle <- tbl$storage$location$handle
  entry <- get(handle$id, envir = credential_env)
  rm(list = handle$id, envir = credential_env)
  withr::defer(assign(handle$id, entry, envir = credential_env))
  expect_error(lake_load(copy), class = "zulake_error_auth")
  expect_identical(calls, 1)
})

test_that("a handle's credentials go when nothing holds the handle", {
  h <- credential_handle(function() "tok", "abfss://lake@acct.dfs.core.windows.net/t")
  id <- h$id
  expect_true(exists(id, envir = credential_env))
  rm(h)
  gc()
  expect_false(exists(id, envir = credential_env))
})

test_that("the three URI forms make the same requests", {
  requests <- lapply(c("abfss", "dfs", "blob"), function(form) {
    log <- new.env()
    local_azure_fake(azure_fake(fake_root(), log))
    local_empty_download_cache()
    lake_read(lake_open(paste0(fake_uri("zl-partitioned", form), "/"), credentials = function() "tok"))
    lapply(log$requests, function(r) r[c("method", "url", "headers")])
  })
  expect_gt(length(requests[[1L]]), 3L)
  expect_identical(requests[[2L]], requests[[1L]])
  expect_identical(requests[[3L]], requests[[1L]])
  # Upper case in the host is the same account; the path is percent-decoded.
  log <- new.env()
  local_azure_fake(azure_fake(fake_root(), log))
  storage_for("https://ACCT.blob.core.windows.net/lake/zl%2Dbasic", NULL)$list("_delta_log/")
  expect_identical(log$requests[[1L]]$host, "acct.blob.core.windows.net")
  expect_identical(log$requests[[1L]]$query$prefix, "zl-basic/_delta_log/")
  # A table at the root of a container.
  log <- new.env()
  local_azure_fake(azure_fake(fake_root(), log))
  storage_for("abfss://lake@acct.dfs.core.windows.net", NULL)$list("_delta_log/")
  expect_identical(log$requests[[1L]]$query$prefix, "_delta_log/")
})

test_that("other schemes and malformed Azure URIs are refused, and a SAS is not repeated", {
  refused <- c(
    "s3://bucket/table", "gs://bucket/table", "abfs://lake@acct.dfs.core.windows.net/t",
    "wasbs://lake@acct.blob.core.windows.net/t", "http://acct.blob.core.windows.net/lake/t",
    "https://example.com/lake/t", "https://acct.file.core.windows.net/lake/t",
    "https://acct.blob.core.chinacloudapi.cn/lake/t", "file:///tmp/t", "az://lake/t",
    "https://acct.blob.core.windows.net", "https://acct.blob.core.windows.net/",
    "abfss://@acct.dfs.core.windows.net/t", "abfss://lake@.dfs.core.windows.net/t",
    "abfss://lake@acct.blob.core.windows.net/t",
    "abfss://lake@acct.dfs.core.windows.net/a//b", "abfss://lake@acct.dfs.core.windows.net/a/../b",
    "abfss://lake@acct.dfs.core.windows.net/./b",
    "https://acct.blob.core.windows.net/lake/t?sv=2023&sig=SECRETSIG",
    "https://acct.blob.core.windows.net/lake/t#frag",
    "https://user:SECRETPW@acct.blob.core.windows.net/lake/t",
    "abfss://user:SECRETPW@lake@acct.dfs.core.windows.net/t"
  )
  local_azure_fake(zuhttp::zu_mock_transport(function(req) stop("no request may be sent")))
  for (uri in refused) {
    e <- catch_error(lake_open(uri), "zulake_error_uri")
    expect_false(grepl("SECRET", conditionMessage(e)), label = uri)
    expect_no_token(e, "SECRETSIG")
    expect_no_token(e, "SECRETPW")
    expect_error(lake_is_table(uri), class = "zulake_error_uri")
  }
})

test_that("account and container names are checked at their limits", {
  local_azure_fake(azure_fake(fake_root(), new.env()))
  ok <- function(account, container) {
    uri <- sprintf("abfss://%s@%s.dfs.core.windows.net/t", container, account)
    !inherits(tryCatch(storage_for(uri, NULL), zulake_error_uri = function(e) e), "error")
  }
  a <- function(n) strrep("a", n)
  expect_identical(vapply(c(2, 3, 24, 25), function(n) ok(a(n), "lake"), NA), c(FALSE, TRUE, TRUE, FALSE))
  expect_identical(vapply(c(2, 3, 63, 64), function(n) ok("acct", a(n)), NA), c(FALSE, TRUE, TRUE, FALSE))
  expect_false(ok("Acct_1", "lake"))
  expect_true(ok("acct", "a-b-c"))
  expect_true(ok("acct", "$root"))
  for (container in c("a--b", "-ab", "ab-", "Lake", "la_ke", "la.ke")) expect_false(ok("acct", container), label = container)
})

test_that("without zulake.azure_client, requests go out with one zuhttp client per session, named zulake", {
  withr::local_options(zulake.azure_client = NULL)
  old <- azure_env$client
  azure_env$client <- NULL
  withr::defer(azure_env$client <- old)
  client <- azure_client()
  expect_s3_class(client, "zu_client")
  expect_s3_class(client$transport, "zu_native_transport")
  expect_identical(client$user_agent, paste0("zulake/", utils::packageVersion("zulake")))
  expect_identical(azure_client(), client)
  withr::local_options(zulake.azure_client = "not a client")
  expect_error(azure_client(), class = "zulake_error_argument")
})

test_that("zulake.azure_endpoint sends every request to a path-style endpoint", {
  log <- new.env()
  withr::local_options(
    zulake.azure_client = fake_client(azure_fake(fake_root(), log)),
    zulake.azure_endpoint = "https://127.0.0.1:10000/devstoreaccount1/"
  )
  tbl <- lake_open(fake_uri("zl-basic"), credentials = function() "tok")
  expect_true(all(vapply(log$requests, function(r) startsWith(r$url, "https://127.0.0.1:10000/devstoreaccount1/lake"), NA)))
  # The snapshot's own location is still the URI given.
  expect_identical(tbl$uri, fake_uri("zl-basic"))
  expect_true(all(startsWith(lake_files(tbl)$uri, fake_uri("zl-basic"))))
  withr::local_options(zulake.azure_endpoint = 1)
  expect_error(lake_open(fake_uri("zl-basic")), class = "zulake_error_argument")
  withr::local_options(zulake.azure_endpoint = NULL, zulake.azure_client = "client")
  expect_error(lake_open(fake_uri("zl-basic")), class = "zulake_error_argument")
})

test_that("an absolute Azure path in the log is read with the table's credentials", {
  dir <- withr::local_tempdir()
  src <- fixture_table("zl-basic")
  tbl0 <- lake_open(src)
  files <- lake_files(tbl0, stats = FALSE)
  path <- file.path(dir, "abs")
  # Its data files under another prefix of the container, named by URI.
  dir.create(file.path(dir, "elsewhere"))
  file.copy(file.path(src, files$path), file.path(dir, "elsewhere"))
  lines <- c(protocol_line(), metadata_line(c(id = "long", label = "string", x = "double")),
             vapply(seq_len(nrow(files)), function(i) {
               add_line(paste0("abfss://lake@acct.dfs.core.windows.net/elsewhere/", files$path[i]),
                        size = files$size_bytes[i])
             }, ""))
  write_commit(path, 0, lines)
  log <- new.env()
  local_azure_fake(azure_fake(dir, log, auth = function(h) if (!identical(h, "Bearer tok")) 401L))
  tbl <- lake_open(fake_uri("abs"), credentials = function() "tok")
  got <- lake_read(tbl)
  expect_identical(got[order(got$id), ], lake_read(tbl0)[order(lake_read(tbl0)$id), ], ignore_attr = "row.names")
  gets <- Filter(function(r) startsWith(r$path, "elsewhere/"), log$requests)
  expect_length(gets, nrow(files))
  # On a local table the same path is not readable.
  write_commit(file.path(dir, "local"), 0, lines)
  expect_error(lake_read(lake_open(file.path(dir, "local"))), class = "zulake_error_uri")
})

test_that("the List Blobs parser reads Azure's documented answer and refuses others", {
  # The response body example of Azure's List Blobs reference (2023-11-03),
  # cut to the fields zulake reads, with a name that needs escaping.
  xml <- paste0(
    '<?xml version="1.0" encoding="utf-8"?>',
    '<EnumerationResults ServiceEndpoint="https://myaccount.blob.core.windows.net/" ContainerName="mycontainer">',
    "<Prefix>t/_delta_log/</Prefix><Marker>m0</Marker><MaxResults>3</MaxResults><Delimiter>/</Delimiter>",
    "<Blobs>",
    "<Blob><Name>t/_delta_log/00000000000000000000.json</Name><Properties>",
    "<Creation-Time>Wed, 25 Nov 2026 10:00:00 GMT</Creation-Time>",
    "<Last-Modified>Thu, 26 Nov 2026 16:04:00 GMT</Last-Modified><Etag>0x8D</Etag>",
    "<Content-Length>1522</Content-Length><BlobType>BlockBlob</BlobType></Properties>",
    "<Metadata><a>1</a></Metadata></Blob>",
    "<BlobPrefix><Name>t/_delta_log/_sidecars/</Name></BlobPrefix>",
    "<Blob><Name>t/_delta_log/a&amp;b&lt;&#233;&#x20AC;.json</Name><Properties>",
    "<Last-Modified>Mon, 01 Jan 2024 00:00:59 GMT</Last-Modified><Content-Length>0</Content-Length>",
    "</Properties><Metadata /></Blob>",
    '<Blob><Name Encoded="true">t/_delta_log/%01x.json</Name><Properties>',
    "<Last-Modified>Mon, 01 Jan 2024 00:00:00 GMT</Last-Modified><Content-Length>7</Content-Length>",
    "</Properties></Blob>",
    "<Blob><Name>t/_delta_log/dir</Name><Properties>",
    "<Last-Modified>Mon, 01 Jan 2024 00:00:00 GMT</Last-Modified><Content-Length>0</Content-Length>",
    "</Properties><Metadata><hdi_isfolder>true</hdi_isfolder></Metadata></Blob>",
    "</Blobs><NextMarker>2!72!MDAwMDcy</NextMarker></EnumerationResults>"
  )
  page <- parse_blob_list(charToRaw(xml), "_delta_log/")
  expect_identical(page$blobs$name, c(
    "t/_delta_log/00000000000000000000.json", "t/_delta_log/a&b<é€.json", "t/_delta_log/\001x.json"
  ))
  expect_identical(page$blobs$size, c(1522, 0, 7))
  expect_identical(page$blobs$modification_time, c(
    as.numeric(as.POSIXct("2026-11-26 16:04:00", tz = "UTC")),
    as.numeric(as.POSIXct("2024-01-01 00:00:59", tz = "UTC")),
    as.numeric(as.POSIXct("2024-01-01 00:00:00", tz = "UTC"))
  ))
  expect_identical(page$next_marker, "2!72!MDAwMDcy")
  empty <- parse_blob_list(charToRaw("<EnumerationResults><Blobs /><NextMarker /></EnumerationResults>"), "p")
  expect_length(empty$blobs$name, 0L)
  expect_identical(empty$next_marker, NA_character_)
  # A name that looks like markup is a name: only the Blobs element is read
  # for blobs, and NextMarker outside it.
  tricky <- paste0("<EnumerationResults><Blobs><Blob><Name>&lt;NextMarker&gt;x&lt;/NextMarker&gt;</Name>",
                   "<Properties><Last-Modified>Mon, 01 Jan 2024 00:00:00 GMT</Last-Modified>",
                   "<Content-Length>1</Content-Length></Properties></Blob></Blobs><NextMarker/></EnumerationResults>")
  page <- parse_blob_list(charToRaw(tricky), "p")
  expect_identical(page$blobs$name, "<NextMarker>x</NextMarker>")
  expect_identical(page$next_marker, NA_character_)
  # Character references XML does not allow are left as they are.
  expect_identical(xml_decode("a&#0;b&#99999999999;c&#xD800;d&#x10FFFF;e&#x110000;f&unknown;g"),
                   paste0("a&#0;b&#99999999999;c&#xD800;d", intToUtf8(0x10FFFF), "e&#x110000;f&unknown;g"))
  expect_identical(xml_decode("&#1;&#x7F;&amp;amp;"), paste0(intToUtf8(1), intToUtf8(0x7F), "&amp;"))
  bad <- list(
    "", "<html>no</html>", "<EnumerationResults><Blobs>",
    "<EnumerationResults><Blobs><Blob><Properties></Properties></Blob></Blobs></EnumerationResults>",
    "<EnumerationResults><Blobs><Blob><Name>a</Name></Blob></Blobs></EnumerationResults>",
    paste0("<EnumerationResults><Blobs><Blob><Name>a</Name><Properties><Content-Length>x</Content-Length>",
           "<Last-Modified>Mon, 01 Jan 2024 00:00:00 GMT</Last-Modified></Properties></Blob></Blobs></EnumerationResults>"),
    paste0("<EnumerationResults><Blobs><Blob><Name>a</Name><Properties><Content-Length>1</Content-Length>",
           "<Last-Modified>2024-01-01</Last-Modified></Properties></Blob></Blobs></EnumerationResults>")
  )
  for (b in bad) expect_error(parse_blob_list(charToRaw(b), "p"), class = "zulake_error_storage", label = b)
  expect_error(parse_blob_list(as.raw(c(0x3c, 0xff, 0x3e)), "p"), class = "zulake_error_storage")
})

test_that("HTTP dates are read without the locale, and invalid ones are NA", {
  withr::local_locale(c(LC_TIME = "C"))
  expect_identical(parse_http_date("Thu, 26 Nov 2026 16:04:00 GMT"), as.numeric(as.POSIXct("2026-11-26 16:04:00", tz = "UTC")))
  expect_identical(parse_http_date("Thu, 01 Jan 1970 00:00:00 GMT"), 0)
  expect_identical(parse_http_date("Sat, 29 Feb 2025 00:00:00 GMT"), NA_real_)
  expect_identical(parse_http_date("Thu, 29 Feb 2024 23:59:59 GMT"), as.numeric(as.POSIXct("2024-02-29 23:59:59", tz = "UTC")))
  # Hours to 23, minutes to 59, seconds to 60 (a leap second).
  expect_false(is.na(parse_http_date("Thu, 26 Nov 2026 23:59:60 GMT")))
  expect_identical(parse_http_date("Thu, 26 Nov 2026 23:61:00 GMT"), NA_real_)
  expect_identical(parse_http_date("Thu, 26 Nov 2026 23:60:00 GMT"), NA_real_)
  expect_identical(parse_http_date("Thu, 26 Nov 2026 23:59:61 GMT"), NA_real_)
  for (x in list("Thu, 26 Nov 2026 24:00:00 GMT", "Thu, 26 Noe 2026 16:04:00 GMT", "26 Nov 2026 16:04:00 GMT",
                 "Thu, 26 Nov 2026 16:04:00 UTC", NA_character_, "", NULL, c("a", "b"))) {
    expect_identical(parse_http_date(x), NA_real_)
  }
  expect_identical(content_range_total("bytes 0-9/100"), 100)
  expect_identical(content_range_total("bytes */100"), 100)
  expect_identical(content_range_total(character()), NA_real_)
  expect_identical(content_range_total("bytes 0-9/*"), NA_real_)
})

test_that("blob names are percent-encoded by UTF-8 byte, the same way under any locale", {
  names <- c("a b", "p=a%20b", "café", "x/y", "~._-", "€+&?#")
  want <- c("a%20b", "p%3Da%2520b", "caf%C3%A9", "x/y", "~._-", "%E2%82%AC%2B%26%3F%23")
  expect_identical(vapply(names, blob_path_url, "", USE.NAMES = FALSE), want)
  expect_identical(vapply(names, blob_url_path, "", USE.NAMES = FALSE), want)
  expect_identical(url_decode(want), names)
  withr::with_locale(c(LC_CTYPE = "C"), {
    expect_identical(vapply(names, blob_path_url, "", USE.NAMES = FALSE), want)
  })
})

test_that("cassettes recorded from Azurite replay zulake's local answers", {
  withr::local_options(
    zulake.azure_endpoint = paste0("https://127.0.0.1:10000/", azurite_account),
    zulake.azure_client = NULL
  )
  for (table in cassette_tables) {
    if (table == "table-with-dv-small" && !requireNamespace("zuroar", quietly = TRUE)) next
    withr::local_options(zulake.azure_client = zuhttp::zu_client(
      transport = cassette_router(cassette_dir(), table, "replay")
    ))
    got <- cassette_session(table)
    local <- lake_open(fixture_table(table))
    files <- suppressWarnings(lake_files(local))
    files$uri <- NULL
    expect_identical(got$version, lake_version(local), label = table)
    expect_identical(got$files, files, label = table)
    expect_identical(got$read, lake_read(local), label = table)
    if (!is.null(got$rows)) expect_identical(got$rows, lake_deletion_vectors(local)$rows, label = table)
  }
})

test_that("a deletion vector at an absolute Azure path is read with the table's credentials", {
  skip_if_not_installed("zuroar")
  rows <- c(1, 4, 5)
  vec <- dv_bytes(rows)
  dv <- list(storageType = "p", pathOrInlineDv = "abfss://lake@acct.dfs.core.windows.net/elsewhere/dv.bin",
             offset = 1L, sizeInBytes = length(vec), cardinality = length(rows))
  path <- dv_table(dv)
  expect_identical(write_dv_file(file.path(dirname(path), "elsewhere", "dv.bin"), list(vec)), 1)
  log <- new.env()
  local_azure_fake(azure_fake(dirname(path), log, auth = function(h) if (!identical(h, "Bearer tok")) 401L))
  tbl <- lake_open(fake_uri(basename(path)), credentials = function() "tok")
  expect_identical(lake_deletion_vectors(tbl)$rows[[1L]], rows)
  expect_identical(lake_read(tbl)$id, setdiff(0:9, rows) + 0)
  # The vector's bytes, as the fake served them: a range of its blob, with
  # the table's token.
  got <- Filter(function(r) r$path == "elsewhere/dv.bin", log$requests)
  expect_gt(length(got), 0L)
  for (r in got) expect_identical(r$headers$authorization, "Bearer tok")
  ranges <- unlist(lapply(got, function(r) r$headers$range))
  expect_true(sprintf("bytes=1-%.0f", 1 + 4 + length(vec) + 4 - 1) %in% ranges)
})

test_that("a snapshot restored in another session never sends that session's token (#43)", {
  log <- new.env()
  # Every request's token is its own account's: acct's is tok-saved, any
  # other account's tok-other.
  local_azure_fake(azure_fake(fake_root(), log, auth = function(h, host) {
    want <- if (host == "acct.blob.core.windows.net") "Bearer tok-saved" else "Bearer tok-other"
    if (!is.null(h) && !identical(h, want)) 401L
  }))
  other_uri <- "abfss://lake@other.dfs.core.windows.net/zl-basic"
  for (saved_credentials in list(function() "tok-saved", NULL)) {
    # Session A opens and saves a snapshot; session B, as fresh as A was,
    # opens another account's table, then restores A's snapshot.
    local_fresh_credential_registry()
    saved <- serialize(lake_open(fake_uri("zl-basic"), credentials = saved_credentials), NULL)
    local_fresh_credential_registry()
    local_empty_download_cache()
    other <- lake_open(other_uri, credentials = function() "tok-other")
    log$requests <- list()
    copy <- unserialize(saved)
    expect_error(lake_load(copy), class = "zulake_error_auth")
    expect_error(lake_read(copy), class = "zulake_error_auth")
    expect_length(Filter(function(r) r$host == "acct.blob.core.windows.net", log$requests), 0L)
    # A handle given another live handle's id (as a guess, or a collision)
    # still gets no token: the entry is bound to its own table.
    copy$storage$location$handle$id <- other$storage$location$handle$id
    expect_error(lake_load(copy), class = "zulake_error_auth")
    for (id in list("n", "nonce", NA_character_, 1, NULL)) {
      copy$storage$location$handle$id <- id
      expect_error(lake_load(copy), class = "zulake_error_auth")
    }
    expect_length(log$requests, 0L)
    # B's own table still reads, with B's token.
    expect_s3_class(lake_load(other), "zulake_table")
    expect_true(all(vapply(log$requests, function(r) identical(r$headers$authorization, "Bearer tok-other"), NA)))
  }
  # A handle that is not an environment is no handle.
  expect_error(credential_token(list(id = "x")), class = "zulake_error_auth")
  expect_error(credential_token("x"), class = "zulake_error_auth")
})

test_that("two sessions' handle ids differ, and the session's random stream is untouched (#43)", {
  local_fresh_credential_registry()
  a <- credential_handle(NULL, "abfss://lake@acct.dfs.core.windows.net/t")
  local_fresh_credential_registry()
  b <- credential_handle(NULL, "abfss://lake@acct.dfs.core.windows.net/t")
  expect_false(identical(a$id, b$id))
  expect_match(b$id, "^[0-9a-f]{32}-1$")
  set.seed(42)
  want <- runif(3)
  set.seed(42)
  local_fresh_credential_registry()
  credential_handle(NULL, "x")
  expect_identical(runif(3), want)
  expect_match(random_hex(16L), "^[0-9a-f]{32}$")
  # Without a system generator (Windows), R's, reseeded, and the session's
  # stream left as it was, or left unmade.
  local_mocked_bindings(system_random_bytes = function(n) raw())
  set.seed(7)
  want <- runif(2)
  set.seed(7)
  expect_match(random_hex(16L), "^[0-9a-f]{32}$")
  expect_identical(runif(2), want)
  withr::with_preserve_seed({
    rm(".Random.seed", envir = globalenv())
    random_hex(16L)
    expect_false(exists(".Random.seed", envir = globalenv(), inherits = FALSE))
  })
})

test_that("a listing whose markers cycle is an error, not a loop, whatever the cycle's length (#45)", {
  body <- function(marker) {
    paste0(
      "<?xml version=\"1.0\" encoding=\"utf-8\"?><EnumerationResults><Blobs></Blobs>",
      "<NextMarker>", marker, "</NextMarker></EnumerationResults>"
    )
  }
  for (k in 1:3) {
    markers <- paste0("m", seq_len(k))
    log <- new.env()
    local_azure_fake(azure_fake(fake_root(), log, max_requests = 50L, override = function(r) {
      at <- if (is.null(r$query$marker)) 0L else match(r$query$marker, markers)
      zuhttp::zu_response(200L, body = body(markers[at %% k + 1L]))
    }))
    storage <- storage_for(fake_uri("zl-basic"), function() "tok")
    expect_error(storage$list("_delta_log/"), class = "zulake_error_storage", label = k)
    # Every marker asked for once, then the repeat seen and refused.
    expect_length(log$requests, k + 1L)
  }
})

test_that("ContainerNotFound after the first page fails the listing, not ends it (#46)", {
  log <- new.env()
  local_azure_fake(azure_fake(fake_root(), log, page_size = 2L, override = function(r) {
    if (!is.null(r$query$marker)) zuhttp::zu_response(404L, c(`x-ms-error-code` = "ContainerNotFound"))
  }))
  storage <- storage_for(fake_uri("zl-basic"), function() "tok")
  e <- expect_error(storage$list("_delta_log/"), class = "zulake_error_storage")
  expect_identical(e$status, 404L)
  expect_identical(e$code, "ContainerNotFound")
  expect_error(lake_open(fake_uri("zl-basic"), credentials = function() "tok"), class = "zulake_error_storage")
  # On the first page it is still a container with nothing in it.
  expect_false(lake_is_table("abfss://other@acct.dfs.core.windows.net/zl-basic"))
})

test_that("a token is checked after its Bearer prefix is dropped, in any case (#47)", {
  for (bad in c("Bearer ", "Bearer   ", "bearer ", " lead", "tok en", "tok\ten", "Bearer tok en")) {
    log <- new.env()
    local_azure_fake(azure_fake(fake_root(), log))
    expect_error(lake_open(fake_uri("zl-basic"), credentials = function() bad), class = "zulake_error_auth",
                 label = bad)
    expect_length(log$requests, 0L)
  }
  for (good in c("bearer x", "BEARER x", "Bearer x", "BeArEr   x", "x")) {
    log <- new.env()
    local_azure_fake(azure_fake(fake_root(), log))
    lake_open(fake_uri("zl-basic"), credentials = function() good)
    expect_identical(unique(vapply(log$requests, function(r) r$headers$authorization, "")), "Bearer x", label = good)
  }
})

test_that("NUL and invalid UTF-8 in List Blobs answers are classed errors (#49)", {
  head <- "<?xml version=\"1.0\" encoding=\"utf-8\"?><EnumerationResults><Blobs>"
  blob <- function(name, encoded = TRUE) {
    paste0(if (encoded) "<Blob><Name Encoded=\"true\">" else "<Blob><Name>", name, "</Name><Properties>",
           "<Last-Modified>Mon, 01 Jan 2024 00:00:00 GMT</Last-Modified><Content-Length>1</Content-Length>",
           "</Properties></Blob>")
  }
  tail <- "</Blobs><NextMarker /></EnumerationResults>"
  for (name in c("t/a%00b", "t/a%C3%28b", "t/a%FFb")) {
    expect_error(parse_blob_list(charToRaw(paste0(head, blob(name), tail)), "p"), class = "zulake_error_storage",
                 label = name)
  }
  with_nul <- c(charToRaw(paste0(head, blob("t/a", FALSE))), as.raw(0), charToRaw(tail))
  expect_error(parse_blob_list(with_nul, "p"), class = "zulake_error_storage")
  utf16 <- iconv(paste0(head, blob("t/a", FALSE), tail), "UTF-8", "UTF-16LE", toRaw = TRUE)[[1L]]
  expect_error(parse_blob_list(utf16, "p"), class = "zulake_error_storage")
  expect_identical(parse_blob_list(charToRaw(paste0(head, blob("t/a%C3%A9"), tail)), "p")$blobs$name, "t/aé")
})

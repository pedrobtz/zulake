# The assertion helpers of helper-*.R, which other tests assert through
# (#82): each fails when it should, on a known wrong value, and passes on
# the right one. A helper that cannot see a failure makes every test
# through it pass. expect_oracle() has its own in test-fixtures.R.

test_that("expect_no_token() fails on a token in a field, a closure, an environment, an attribute or a message", {
  token <- azurite_token
  part <- strsplit(token, ".", fixed = TRUE)[[1L]][2L]
  # A closure or an environment of this test would serialize `token` itself.
  clean <- list(a = "x", f = local(function() 1, envir = new.env(parent = baseenv())),
                e = new.env(parent = emptyenv()), n = structure(1, note = "y"))
  expect_identical(expectation_counts(expect_no_token(clean, token))$failure, 0L)
  held <- local({
    secret <- token
    function() secret
  })
  env <- new.env()
  env$header <- paste("Bearer", token)
  leaks <- list(
    field = list(a = "x", b = list(c = token)),
    part = list(a = paste0("<", part, ">")),
    closure = list(f = held),
    environment = list(e = env),
    attribute = structure(list(), secret = token),
    message = simpleError(paste("refused with", token))
  )
  for (where in names(leaks)) {
    expect_gt(expectation_counts(expect_no_token(leaks[[where]], token))$failure, 0L, label = where)
  }
  # Only in the printed form: the object holds the token's bytes reversed.
  shown <- structure(list(reversed = rev(charToRaw(token))), class = "zulake_test_shows_token")
  expect_false(length(grepRaw(token, serialize(shown, NULL), fixed = TRUE)) > 0L)
  expect_gt(expectation_counts(expect_no_token(shown, token))$failure, 0L)
})

test_that("expect_read_oracle() passes on deltalake's read and fails on a changed one", {
  read <- lake_read(lake_open(fixture_table("zl-basic"), version = 3))
  counts <- expectation_counts(expect_read_oracle(read, "zl-basic", 3))
  expect_identical(counts$failure, 0L)
  expect_gt(counts$success, 0L)
  expect_identical(expectation_counts(expect_read_oracle(read[rev(seq_len(nrow(read))), ], "zl-basic", 3))$failure, 0L)
  wrong <- list(
    value = within(read, x[1L] <- x[1L] + 1),
    row = read[-1L, ],
    duplicate = read[c(1L, seq_len(nrow(read))), ],
    column = read[-1L],
    extra = cbind(read, extra = 1),
    version = read
  )
  for (what in names(wrong)) {
    version <- if (what == "version") 2 else 3
    expect_gt(expectation_counts(expect_read_oracle(wrong[[what]], "zl-basic", version))$failure, 0L, label = what)
  }
})

test_that("azure_fake() serves the files under its root and records each request as it was sent", {
  root <- fake_root()
  log <- new.env()
  client <- fake_client(azure_fake(root, log))
  base <- "https://acct.blob.core.windows.net/lake/"
  file <- "zl-basic/_delta_log/00000000000000000000.json"
  bytes <- readBin(file.path(root, file), "raw", file.size(file.path(root, file)))
  get <- function(url, headers = c(`x-ms-version` = "v")) {
    zuhttp::zu_get(url, headers = headers, check = FALSE, decode = FALSE, client = client)
  }

  resp <- get(paste0(base, file), c(`x-ms-version` = "v", Authorization = "Bearer t"))
  expect_identical(zuhttp::zu_resp_status(resp), 200L)
  expect_identical(zuhttp::zu_resp_raw(resp), bytes)
  rec <- log$requests[[1L]]
  expect_identical(rec[c("method", "host", "container", "path")],
                   list(method = "GET", host = "acct.blob.core.windows.net", container = "lake", path = file))
  expect_identical(rec$headers[["x-ms-version"]], "v")
  expect_identical(rec$headers$authorization, "Bearer t")

  resp <- get(paste0(base, file), c(`x-ms-version` = "v", Range = "bytes=2-9"))
  expect_identical(zuhttp::zu_resp_status(resp), 206L)
  expect_identical(zuhttp::zu_resp_raw(resp), bytes[3:10])
  expect_identical(zuhttp::zu_resp_header(resp, "content-range"), sprintf("bytes 2-9/%d", length(bytes)))
  resp <- zuhttp::zu_head(paste0(base, file), headers = c(`x-ms-version` = "v"), check = FALSE, client = client)
  expect_identical(zuhttp::zu_resp_header(resp, "content-length"), as.character(length(bytes)))
  expect_identical(log$requests[[3L]]$method, "HEAD")

  resp <- get(paste0(base, "zl-basic/no-such-file"))
  expect_identical(zuhttp::zu_resp_header(resp, "x-ms-error-code"), "BlobNotFound")
  resp <- get(paste0("https://acct.blob.core.windows.net/other/", file))
  expect_identical(zuhttp::zu_resp_header(resp, "x-ms-error-code"), "ContainerNotFound")
  # Path-style, as Azurite's: the account is the first segment.
  get(paste0("https://127.0.0.1:10000/devstoreaccount1/lake/", file))
  expect_identical(log$requests[[6L]][c("host", "container", "path")],
                   list(host = "127.0.0.1:10000/devstoreaccount1", container = "lake", path = file))
  expect_length(log$requests, 6L)
})

test_that("azure_fake() lists every blob under a prefix once, in byte order, across pages", {
  root <- fake_root()
  prefix <- "zl-basic/_delta_log/"
  want <- paste0(prefix, sort(list.files(file.path(root, prefix), all.files = TRUE, no.. = TRUE), method = "radix"))
  for (page_size in c(1L, 2L, 1000L)) {
    log <- new.env()
    client <- fake_client(azure_fake(root, log, page_size = page_size))
    names <- character()
    marker <- NULL
    repeat {
      query <- list(restype = "container", comp = "list", prefix = prefix, delimiter = "/")
      query$marker <- marker
      body <- zuhttp::zu_resp_raw(zuhttp::zu_get("https://acct.blob.core.windows.net/lake", query = query,
                                                 headers = c(`x-ms-version` = "v"), check = FALSE, decode = FALSE,
                                                 client = client))
      text <- rawToChar(body)
      names <- c(names, regmatches(text, gregexpr("(?<=<Name>)[^<]+", text, perl = TRUE))[[1L]])
      marker <- regmatches(text, regexpr("(?<=<NextMarker>)[^<]+", text, perl = TRUE))
      if (!length(marker)) break
    }
    expect_identical(names, want, label = page_size)
    expect_length(log$requests, as.integer(ceiling(length(want) / page_size)))
    expect_identical(log$requests[[1L]]$query$prefix, prefix)
  }
})

test_that("azure_fake() stops a runaway loop and a path Azure would not serve as the file it names", {
  log <- new.env()
  client <- fake_client(azure_fake(fake_root(), log, max_requests = 2L))
  url <- "https://acct.blob.core.windows.net/lake/zl-basic/_delta_log/00000000000000000000.json"
  get <- function(url) zuhttp::zu_get(url, headers = c(`x-ms-version` = "v"), check = FALSE, client = client)
  for (i in 1:2) get(url)
  expect_error(get(url), "more than 2 requests")
  client <- fake_client(azure_fake(fake_root(), new.env()))
  for (bad in c("zl-basic/./x", "zl-basic/../zl-types/x", "zl-basic//x", "zl-basic/")) {
    expect_error(get(paste0("https://acct.blob.core.windows.net/lake/", bad)), "empty", label = bad)
  }
})

# The example table the package ships (inst/extdata/orders, roadmap Stage 7):
# the zl-orders fixture file for file, so deltalake 1.7.0's answers for that
# fixture hold for what the README, the vignette and the examples open.

test_that("inst/extdata/orders is the zl-orders fixture, file for file", {
  shipped <- shipped_orders()
  fixture <- fixture_table("zl-orders")
  files <- sort(list.files(fixture, recursive = TRUE, all.files = TRUE), method = "radix")
  expect_gt(length(files), 10L)
  expect_identical(sort(list.files(shipped, recursive = TRUE, all.files = TRUE), method = "radix"), files)
  expect_identical(unname(tools::md5sum(file.path(shipped, files))),
                   unname(tools::md5sum(file.path(fixture, files))))
})

test_that("every path of the shipped table fits the 100 bytes a package tarball allows", {
  files <- list.files(shipped_orders(), recursive = TRUE, all.files = TRUE, include.dirs = TRUE)
  expect_lte(max(nchar(file.path("zulake", "inst", "extdata", "orders", files), "bytes")), 100L)
})

test_that("the shipped table equals deltalake's answers at every version", {
  path <- shipped_orders()
  expect_identical(oracle_versions("zl-orders"), c(0, 1, 2, 3, 4))
  for (version in oracle_versions("zl-orders")) {
    expect_null(oracle_refusal("zl-orders", version))
    tbl <- lake_open(path, version = version)
    expect_identical(lake_version(tbl), version)
    answer <- oracle_field("zl-orders", version, "add_actions")
    expect_oracle(replay_files_frame(tbl, names(answer$columns)), "zl-orders", version, "add_actions")
    files <- lake_files(tbl)
    expect_oracle(files["num_records"], "zl-orders", version, "add_actions")
    expect_true(all(file.exists(files$uri)))
    expect_oracle(lake_count(tbl), "zl-orders", version, "count")
    expect_read_oracle(lake_read(tbl), "zl-orders", version)
    h <- lake_history(tbl)
    expect_oracle(lapply(seq_len(nrow(h)), function(i) c(h$commit_info[[i]], list(version = h$version[i]))),
                  "zl-orders", version, "history")
    tx <- lake_transactions(tbl)
    expect_identical(oracle_canon(as.list(stats::setNames(tx$version, tx$app_id))),
                     oracle_canon(strip_nulls(oracle_field("zl-orders", version, "transactions")) %||%
                                    structure(list(), names = character())))
  }
})

test_that("the shipped table's commit times come from the log, whatever its files' times", {
  # An installed package gives its files the install time: in-commit
  # timestamps keep the versions on their days.
  path <- local_fixture_copy("zl-orders")
  log <- list.files(file.path(path, "_delta_log"), full.names = TRUE)
  stopifnot(Sys.setFileTime(log, Sys.time()))
  expect_true("inCommitTimestamp" %in% lake_protocol(lake_open(path))$name)
  v <- lake_versions(lake_open(path))
  for (i in seq_len(nrow(v))) {
    at <- oracle_field("zl-orders", v$version[i], "timestamp_lookup")[[2L]]
    expect_identical(v$timestamp[i], answer_time(at$at))
  }
  expect_identical(format(v$timestamp, "%Y-%m-%d %H:%M", tz = "UTC"),
                   sprintf("2025-01-%02d 09:00", 6:10))
  day <- as.POSIXct("2025-01-08 12:00", tz = "UTC")
  expect_identical(lake_version(lake_open(path, timestamp = day)), 2)
  expect_identical(lake_version(lake_open(shipped_orders(), timestamp = day)), 2)
})

test_that("every exported function is called by an example that opens the shipped table", {
  code <- example_code()
  opens <- vapply(code, function(x) any(grepl('system.file("extdata", "orders", package = "zulake")', x,
                                              fixed = TRUE)), NA)
  for (fn in getNamespaceExports("zulake")) {
    calls <- vapply(code, function(x) any(grepl(paste0("\\b", fn, "\\("), x)), NA)
    expect_true(any(calls & opens), label = paste(fn, "in an example on inst/extdata/orders"))
  }
  expect_gte(length(getNamespaceExports("zulake")), 25L)
})

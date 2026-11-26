# lake_open(), lake_is_table(), lake_load(), lake_version(): their arguments
# and the local storage backend.

test_that("lake_open() refuses a uri that is not one non-empty string", {
  for (uri in list(NA_character_, c("a", "b"), 1, character(), "", NULL, factor("a"), list("a"))) {
    expect_error(lake_open(uri), class = "zulake_error_argument")
    expect_error(lake_is_table(uri), class = "zulake_error_argument")
  }
})

test_that("version must be one whole number from 0, and not with a timestamp", {
  path <- fixture_table("zl-basic")
  for (v in list(NA, NA_real_, -1, 1.5, "1", Inf, -Inf, NaN, c(1, 2), numeric(), TRUE, factor(1), as.POSIXct("2020-01-01"))) {
    expect_error(lake_open(path, version = v), class = "zulake_error_argument", label = deparse(v))
  }
  expect_identical(lake_version(lake_open(path, version = 2L)), 2)
  expect_identical(lake_version(lake_open(path, version = 0)), 0)
  expect_error(
    lake_open(path, version = 1, timestamp = as.POSIXct("2030-01-01", tz = "UTC")),
    class = "zulake_error_argument"
  )
})

test_that("a version past the end of the log is refused", {
  path <- fixture_table("zl-basic")
  expect_identical(lake_version(lake_open(path, version = 4)), 4)
  expect_no_snapshot(lake_open(path, version = 5), "zulake_error_version")
  expect_identical(tryCatch(lake_open(path, version = 5), error = identity)$version, 5)
})

test_that("timestamp must be one POSIXct", {
  path <- fixture_table("zl-basic")
  for (t in list("2020-01-01", as.Date("2020-01-01"), 1, NA, as.POSIXct(NA), as.POSIXct(c("2020-01-01", "2021-01-01")),
                 as.POSIXlt("2020-01-01"), .POSIXct(Inf))) {
    expect_error(lake_open(path, timestamp = t), class = "zulake_error_argument")
  }
})

test_that("credentials must be NULL or a function", {
  path <- fixture_table("zl-basic")
  expect_error(lake_open(path, credentials = "token"), class = "zulake_error_argument")
  expect_error(lake_is_table(path, credentials = 1), class = "zulake_error_argument")
  # Not used for a local path, and never called.
  called <- FALSE
  tbl <- lake_open(path, credentials = function() {
    called <<- TRUE
    "x"
  })
  expect_false(called)
  expect_identical(lake_version(tbl), 4)
})

test_that("URIs with a scheme other than Azure's are refused, naming the scheme", {
  # The Azure forms, and their refusals, are test-azure.R's.
  for (uri in c("s3://b/t", "gs://b/t", "file:///tmp/t", "abfs://c@acct.dfs.core.windows.net/t",
                "wasbs://c@acct.blob.core.windows.net/t", "http://acct.blob.core.windows.net/c/t")) {
    err <- tryCatch(lake_open(uri), error = identity)
    expect_s3_class(err, "zulake_error_uri")
    expect_identical(err$scheme, sub("://.*$", "", uri))
    expect_error(lake_is_table(uri), class = "zulake_error_uri")
  }
})

test_that("a location without a Delta log is not a table", {
  empty <- withr::local_tempdir()
  for (path in c(empty, file.path(empty, "nothing-here"))) {
    expect_false(lake_is_table(path))
    expect_no_snapshot(lake_open(path), "zulake_error_not_table")
  }
  dir.create(file.path(empty, "_delta_log"))
  writeLines("x", file.path(empty, "_delta_log", "00000000000000000000.json.tmp"))
  expect_false(lake_is_table(empty))
  expect_no_snapshot(lake_open(empty), "zulake_error_not_table")
})

test_that("lake_is_table() finds every fixture, and reads no log file", {
  for (table in fixture_names("tables")) {
    expect_true(lake_is_table(fixture_table(table)), label = table)
  }
  for (log in fixture_names("hostile")) {
    expect_true(lake_is_table(fixture_table(log, "hostile")), label = log)
  }
})

test_that("lake_load() and lake_version() refuse what is not a snapshot", {
  for (x in list(NULL, 1, "zl-basic", list(version = 1))) {
    expect_error(lake_load(x), class = "zulake_error_argument")
    expect_error(lake_version(x), class = "zulake_error_argument")
  }
  tbl <- lake_open(fixture_table("zl-basic"))
  expect_error(lake_load(tbl, version = -1), class = "zulake_error_argument")
  expect_error(lake_load(tbl, version = 9), class = "zulake_error_version")
})

test_that("a snapshot holds its fields", {
  tbl <- lake_open(fixture_table("zl-partitioned"))
  expect_s3_class(tbl, "zulake_table")
  expect_identical(tbl$format, "delta")
  expect_identical(tbl$uri, fixture_table("zl-partitioned"))
  expect_identical(tbl$metadata[["partitionColumns"]], c("p_str", "p_int", "p_date"))
  expect_identical(tbl$metadata$schema[["type"]], "struct")
  expect_s3_class(tbl$timestamp, "POSIXct")
  expect_identical(attr(tbl$timestamp, "tzone"), "UTC")
  expect_identical(tbl$commit_info[["operation"]], "DELETE")
  expect_named(tbl$files, c("path", "deletion_vector_id", "action"))
  expect_named(tbl$removed, c("path", "deletion_vector_id", "action"))
  expect_identical(tbl$storage$kind, "local")
})

test_that("every error is a zulake_error", {
  path <- fixture_table("zl-basic")
  for (expr in list(
    quote(lake_open(NA)), quote(lake_open(path, version = 99)), quote(lake_open(withr::local_tempdir())),
    quote(lake_open("s3://x/y")), quote(lake_open(fixture_table("corrupt-commit", "hostile"))),
    quote(lake_open(fixture_table("zl-unknown-reader-feature")))
  )) {
    err <- tryCatch(eval(expr), error = identity)
    expect_s3_class(err, "zulake_error")
    expect_true(grepl("^zulake_error_", class(err)[1L]), label = class(err)[1L])
  }
})

# ---- local storage -----------------------------------------------------------

test_that("the local backend lists files in byte order, without directories", {
  dir <- withr::local_tempdir()
  names <- c("b", "Z", "a", "_z", ".hidden", "é", "10", "9")
  for (n in names) writeLines(n, file.path(dir, n))
  dir.create(file.path(dir, "sub"))
  writeLines("inner", file.path(dir, "sub", "inner"))
  s <- zulake:::storage_local(dir)
  listing <- s$list("")
  expect_identical(listing$name, withr::with_collate("C", sort(names)))
  expect_identical(listing$size, as.numeric(file.size(file.path(dir, listing$name))))
  expect_s3_class(listing$modification_time, "POSIXct")
  expect_identical(s$list("", after = "_z")$name, c("a", "b", "é"))
  expect_identical(s$list("", after = "a")$name, c("b", "é"))
  expect_identical(s$list("", after = "é")$name, character())
  expect_identical(s$list("", after = "0")$name, c("10", "9", "Z", "_z", "a", "b", "é"))
  expect_identical(nrow(s$list("nope/")), 0L)
  expect_error(s$list("", after = NA_character_), class = "zulake_error_argument")
})

test_that("byte order holds whatever the session's collation", {
  x <- c("b", "B", "a", "é", "Z", "_")
  withr::local_collate("en_US.UTF-8")
  expect_identical(zulake:::sorts_after(x, "Z"), c(TRUE, FALSE, TRUE, TRUE, FALSE, TRUE))
  expect_identical(zulake:::sorts_after(character(), "a"), logical())
})

test_that("the local backend reads whole files, ranges and heads", {
  dir <- withr::local_tempdir()
  bytes <- as.raw(0:255)
  writeBin(bytes, file.path(dir, "f.bin"))
  s <- zulake:::storage_local(dir)
  expect_identical(s$get("f.bin"), bytes)
  expect_identical(s$get_range("f.bin", 0, 0), bytes[1L])
  expect_identical(s$get_range("f.bin", 10, 19), bytes[11:20])
  expect_identical(s$get_range("f.bin", 254, 255), bytes[255:256])
  for (r in list(c(-1, 3), c(5, 4), c(0, 256), c(0.5, 3), c(NA, 3))) {
    expect_error(s$get_range("f.bin", r[1], r[2]), class = "zulake_error_storage")
  }
  expect_identical(s$head("f.bin")$size, 256)
  expect_null(s$head("missing"))
  expect_null(s$head(""))
  expect_error(s$get("missing"), class = "zulake_error_storage")
  expect_error(s$get_range("missing", 0, 1), class = "zulake_error_storage")
  writeBin(raw(), file.path(dir, "empty"))
  expect_identical(s$get("empty"), raw())
})

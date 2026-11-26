# 64-bit values and decimal statistics from the log (design section 7, D10):
# exact as a double up to 2^53 - 1, an error beyond unless
# int64 = "integer64", and decimal statistics as their JSON text.

test_that("every 64-bit value from the log straddles 2^53: exact, then an error, or exact as integer64", {
  skip_if_not_installed("bit64")
  for (text in c("9007199254740991", "9007199254740992", "9007199254740993",
                 "-9007199254740991", "-9007199254740992")) {
    path <- int64_table(text)
    tbl <- lake_open(path)
    exact <- text %in% c("9007199254740991", "-9007199254740991")
    negative <- startsWith(text, "-")
    # Each function and column that carries the value, as a function of
    # int64; `tree` marks values inside an action or commitInfo, which are
    # integer64 only where a double cannot hold them.
    getters <- list(
      txn = function(i) lake_transactions(tbl, int64 = i)$version,
      history = function(i) lake_history(tbl, int64 = i)$commit_info[[1L]]$operationMetrics$n,
      min = function(i) lake_files(tbl, int64 = i)$min[[1L]]$id,
      max = function(i) lake_files(tbl, int64 = i)$max[[1L]]$id,
      partition = function(i) lake_files(tbl, stats = FALSE, int64 = i)$partition[[1L]]$p,
      partitions = function(i) lake_partitions(tbl, int64 = i)$p
    )
    tree <- "history"
    if (!negative) {
      getters <- c(getters, list(
        size = function(i) lake_files(tbl, stats = FALSE, int64 = i)$size_bytes,
        action = function(i) lake_actions(tbl, 1, int64 = i)$action[[3L]]$size,
        removed = function(i) lake_removed(tbl, int64 = i)$size_bytes,
        changes = function(i) lake_changes(tbl, from = 0, int64 = i)$size_bytes[1L],
        num_records = function(i) lake_files(tbl, int64 = i)$num_records,
        null_count = function(i) lake_files(tbl, int64 = i)$null_count[[1L]]$id,
        cardinality = function(i) lake_files(tbl, stats = FALSE, int64 = i)$deletion_vector[[1L]]$cardinality,
        bytes = function(i) lake_summary(tbl, int64 = i)$bytes,
        deleted = function(i) lake_summary(tbl, int64 = i)$deleted_rows
      ))
      tree <- c(tree, "action")
    }
    for (what in names(getters)) {
      get <- getters[[what]]
      label <- paste(what, text)
      if (exact) {
        expect_identical(get("double"), as.numeric(text), label = label)
        expect_identical(sprintf("%.0f", get("double")), text, label = label)
      } else {
        err <- tryCatch(get("double"), error = identity)
        expect_s3_class(err, "zulake_error_int64")
        expect_identical(err$value, text, label = label)
      }
      got <- get("integer64")
      if (exact && what %in% tree) {
        expect_identical(got, as.numeric(text), label = label)
      } else {
        expect_s3_class(got, "integer64")
        expect_identical(as.character(got), text, label = label)
      }
    }
    # A filter on the 64-bit partition column compares exactly.
    expect_identical(nrow(lake_files(tbl, filter = p == bit64::as.integer64(text), int64 = "integer64")), 1L)
    if (!negative) {
      # numRecords minus the cardinality: 0. lake_count() has no int64, so a
      # numRecords past 2^53 - 1 is an error there.
      expect_identical(as.character(lake_summary(tbl, int64 = "integer64")$records), "0")
      if (exact) {
        expect_identical(lake_count(tbl), 0)
      } else {
        expect_error(lake_count(tbl), class = "zulake_error_int64")
      }
    }
  }
})

test_that("a sum of counts straddles 2^53 too", {
  skip_if_not_installed("bit64")
  for (second in c("4503599627370495", "4503599627370496")) {
    lines <- c(
      raw_header(),
      raw_add("a.parquet", stats = '{\\"numRecords\\":4503599627370496}', size = "4503599627370496"),
      raw_add("b.parquet", stats = sprintf('{\\"numRecords\\":%s}', second), size = second)
    )
    tbl <- lake_open(raw_table(lines))
    total <- bit64::as.integer64("4503599627370496") + bit64::as.integer64(second)
    if (second == "4503599627370495") {
      expect_identical(lake_count(tbl), 2^53 - 1)
      expect_identical(lake_summary(tbl)$bytes, 2^53 - 1)
    } else {
      expect_error(lake_count(tbl), class = "zulake_error_int64")
      expect_error(lake_summary(tbl), class = "zulake_error_int64")
    }
    expect_identical(as.character(lake_summary(tbl, int64 = "integer64")$records), as.character(total))
    expect_identical(as.character(lake_summary(tbl, int64 = "integer64")$bytes), as.character(total))
  }
})

test_that("integer64 holds -2^63 + 1 to 2^63 - 1; past that, and at bit64's NA, a classed error", {
  skip_if_not_installed("bit64")
  for (text in c("9223372036854775807", "-9223372036854775807", "9223372036854775808", "-9223372036854775808")) {
    lines <- c(raw_header(), raw_add("a.parquet", stats = sprintf('{\\"minValues\\":{\\"id\\":%s}}', text)))
    tbl <- lake_open(raw_table(lines))
    if (text %in% c("9223372036854775807", "-9223372036854775807")) {
      expect_identical(as.character(lake_files(tbl, int64 = "integer64")$min[[1L]]$id), text)
    } else {
      expect_error(lake_files(tbl, int64 = "integer64"), class = "zulake_error_int64")
    }
    expect_error(lake_files(tbl), class = "zulake_error_int64")
    expect_identical(nrow(lake_files(tbl, stats = FALSE)), 1L)
  }
  # zl-types holds long statistics at -2^63 and 2^63 - 1 (deltalake's answer
  # has both).
  tbl <- lake_open(fixture_table("zl-types"))
  expect_identical(oracle_field("zl-types", 0, c("add_actions", "columns", "min"))[[1L]]$i64, "-9223372036854775808")
  expect_error(lake_files(tbl), class = "zulake_error_int64")
  expect_error(lake_files(tbl, int64 = "integer64"), class = "zulake_error_int64")
})

test_that("decimal statistics are the log's JSON text, byte for byte", {
  values <- c("1.234567890123456789", "99999999.99", "1.50", "-0.00", "1E+2", "12345678901234567890123.5", "0")
  for (v in values) {
    lines <- c(
      raw_header(c(dec = "decimal(38,18)", f = "double", n = "integer")),
      raw_add("a.parquet", stats = sprintf('{\\"numRecords\\":1,\\"minValues\\":{\\"dec\\":%s,\\"f\\":%s,\\"n\\":-2147483648},\\"maxValues\\":{\\"dec\\":%s}}', v, v, v))
    )
    f <- lake_files(lake_open(raw_table(lines)))
    expect_identical(f$min[[1L]]$dec, v)
    expect_identical(f$max[[1L]]$dec, v)
    expect_identical(f$min[[1L]]$f, as.numeric(v))
    # An R integer cannot hold -2^31, so `integer` is a double.
    expect_identical(f$min[[1L]]$n, -2147483648)
  }
  # zl-types, as deltalake's writer wrote it: the same text as in the commit.
  commit <- rawToChar(readBin(file.path(fixture_table("zl-types"), "_delta_log", "00000000000000000000.json"),
                              "raw", 1e5))
  stats <- zujson::json_parse(regmatches(commit, regexpr('[{]"add".*', commit)))$add$stats
  dec_min <- regmatches(stats, regexpr('(?<="dec":)[^,}]+', stats, perl = TRUE))
  path <- local_fixture_copy("zl-types")
  # Take out the 64-bit extremes no double or integer64 holds, keep the rest.
  f <- file.path(path, "_delta_log", "00000000000000000000.json")
  text <- rawToChar(readBin(f, "raw", file.size(f)))
  text <- gsub('\\\\"i64\\\\":-?9223372036854775808,?', "", text)
  text <- gsub('\\\\"i64\\\\":9223372036854775807,?', "", text)
  writeBin(charToRaw(text), f)
  files <- lake_files(lake_open(path))
  expect_identical(files$min[[1L]]$dec, dec_min)
  expect_identical(files$min[[1L]]$dec, "-99999999.99")
  expect_identical(files$max[[1L]]$dec38, "1.234567890123457e+19")
  # The rest of zl-types' statistics, typed, equal deltalake's.
  expected <- oracle_field("zl-types", 0, c("add_actions", "columns", "min"))[[1L]]
  for (col in c("i8", "i16", "i32", "d", "ts", "ntz", "s", "flag", "dec")) {
    expect_identical(oracle_canon(files$min[[1L]][[col]]), oracle_canon(expected[[col]]), label = col)
  }
  expect_s3_class(files$min[[1L]]$ts, "POSIXct")
  expect_s3_class(files$min[[1L]]$d, "Date")
})

test_that("mark_numbers() rewrites number tokens only, never digits inside strings", {
  mark <- zulake:::mark_numbers
  x <- '{"a":9007199254740993,"s":"12345678901234567","t":"a\\"9999999999999999","b":[1.5,-9223372036854775808],"c":9007199254740991}'
  parsed <- zujson::json_parse(mark(x))
  expect_identical(parsed$a, "\0369007199254740993")
  expect_identical(parsed$s, "12345678901234567")
  expect_identical(parsed$t, "a\"9999999999999999")
  expect_identical(parsed$b, list(1.5, "\036-9223372036854775808"))
  expect_identical(parsed$c, 9007199254740991)
  all <- zujson::json_parse(mark('{"v":1.50,"w":[1E+2,-0.0],"k":"1.50"}', all = TRUE))
  expect_identical(all, list(v = "\0361.50", w = c("\0361E+2", "\036-0.0"), k = "1.50"))
})

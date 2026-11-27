# 64-bit values and decimal statistics from the log (design section 7, D10):
# exact as a double up to 2^53 - 1, an error beyond unless
# int64 = "integer64", and decimal statistics as their JSON text.

test_that("every 64-bit value from the log straddles 2^53: exact, then an error, or exact as integer64", {
  skip_if_not_installed("bit64")
  # 17 and 18 digits too, between 2^53's 16 and the 19 of 2^63 (#63).
  for (text in c("9007199254740991", "9007199254740992", "9007199254740993",
                 "-9007199254740991", "-9007199254740992", "10000000000000001", "123456789012345678",
                 "-10000000000000001")) {
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

test_that("an array in commitInfo holds its numbers past 2^53 - 1 as integer64, or is an error", {
  path <- hand_table(c(protocol_line(), metadata_line(), add_line("a.parquet"),
    '{"commitInfo":{"timestamp":1,"all":[9007199254740993,-9007199254740994],"some":[9007199254740993,1],"none":[1,2],"text":["a",9007199254740993]}}'))
  tbl <- lake_open(path)
  expect_error(lake_history(tbl), class = "zulake_error_int64")
  skip_if_not_installed("bit64")
  info <- lake_history(tbl, int64 = "integer64")$commit_info[[1L]]
  # What zujson gives each array, with integer64 for what a double cannot hold.
  expect_identical(info$all, bit64::as.integer64(c("9007199254740993", "-9007199254740994")))
  expect_identical(info$some, list(bit64::as.integer64("9007199254740993"), 1L))
  expect_identical(info$none, zujson::json_parse("[1,2]"))
  expect_identical(info$text, list("a", bit64::as.integer64("9007199254740993")))
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
  for (text in c("9223372036854775807", "-9223372036854775807", "-9223372036854775808")) {
    lines <- c(raw_header(c(id = "long", p = "long"), partition = "p"),
               raw_add("a.parquet", partition = sprintf('{"p":"%s"}', text)))
    tbl <- lake_open(raw_table(lines))
    got <- tryCatch(lake_files(tbl, int64 = "integer64")$partition[[1L]]$p, error = identity)
    if (text != "-9223372036854775808") {
      expect_identical(as.character(got), text)
    } else {
      expect_s3_class(got, "zulake_error_int64")
      expect_identical(got$value, text)
    }
    expect_error(lake_files(tbl), class = "zulake_error_int64")
    # Pruning compares the partition value as text, so it never fails.
    expect_identical(length(filter_files(tbl, quote(p == text), environment(), "double")), 1L)
  }
  # Past a long, a partition value is a corrupt log.
  lines <- c(raw_header(c(id = "long", p = "long"), partition = "p"),
             raw_add("a.parquet", partition = '{"p":"9223372036854775808"}'))
  expect_error(lake_open(raw_table(lines)), class = "zulake_error_corrupt_log")
})

test_that("a long statistic the int64 mode cannot hold is NA, with one classed warning per column", {
  skip_if_not_installed("bit64")
  limits <- list(
    double = c(fits = c("9007199254740991", "-9007199254740991"), past = c("9007199254740992", "-9007199254740992")),
    integer64 = c(fits = c("9223372036854775807", "-9223372036854775807"),
                  past = c("9223372036854775808", "-9223372036854775808"))
  )
  for (int64 in names(limits)) {
    for (text in limits[[int64]]) {
      stats <- sprintf('{\\"numRecords\\":1,\\"minValues\\":{\\"id\\":%s,\\"j\\":%s},\\"maxValues\\":{\\"id\\":%s},\\"nullCount\\":{\\"id\\":0}}',
                       text, text, text)
      tbl <- lake_open(raw_table(c(raw_header(c(id = "long", j = "long")), raw_add("a.parquet", stats = stats),
                                   raw_add("b.parquet", stats = stats))))
      got <- collect_warnings(lake_files(tbl, int64 = int64))
      f <- got$value
      label <- paste(int64, text)
      if (text %in% limits[[int64]][1:2]) {
        expect_length(got$warnings, 0L)
        expect_identical(sprintf("%s", as.character(f$min[[2L]]$id)), if (int64 == "double") sprintf("%.0f", as.numeric(text)) else text)
      } else {
        expect_length(got$warnings, 2L)
        for (w in got$warnings) {
          expect_s3_class(w, "zulake_warning_int64")
          expect_s3_class(w, "zulake_warning")
          expect_identical(w$value, text, label = label)
          expect_identical(w$path, "a.parquet", label = label)
        }
        expect_setequal(vapply(got$warnings, function(w) w$column, ""), c("id", "j"))
        expect_true(is.na(f$min[[1L]]$id) && is.na(f$max[[2L]]$id) && is.na(f$min[[2L]]$j), label = label)
        expect_identical(class(f$min[[1L]]$id), if (int64 == "double") "numeric" else "integer64")
        # The exact digits stay in the action.
        expect_true(grepl(text, f$action[[1L]]$stats, fixed = TRUE))
        # Pruning compares them exactly, without a warning.
        expect_identical(nrow(expect_silent(lake_files(tbl, filter = id == text, stats = FALSE))), 2L)
        expect_identical(nrow(lake_files(tbl, filter = id != text, stats = FALSE)), 0L)
      }
    }
  }
  # A count past the limit is still an error.
  stats <- '{\\"numRecords\\":1,\\"nullCount\\":{\\"id\\":9007199254740993}}'
  tbl <- lake_open(raw_table(c(raw_header(), raw_add("a.parquet", stats = stats))))
  expect_error(lake_files(tbl), class = "zulake_error_int64")
  # zl-types holds long statistics at -2^63 and 2^63 - 1 (deltalake's answer
  # has both): NA with a warning in both modes, never an error.
  tbl <- lake_open(fixture_table("zl-types"))
  expect_identical(oracle_field("zl-types", 0, c("add_actions", "columns", "min"))[[1L]]$i64, "-9223372036854775808")
  for (int64 in c("double", "integer64")) {
    got <- collect_warnings(lake_files(tbl, int64 = int64))
    expect_length(got$warnings, 1L)
    expect_s3_class(got$warnings[[1L]], "zulake_warning_int64")
    expect_identical(got$warnings[[1L]]$column, "i64")
    expect_true(is.na(got$value$min[[1L]]$i64))
  }
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
  x <- '{"a":9007199254740993,"s":"12345678901234567","t":"a\\"9999999999999999","b":[1.5,-9223372036854775808],"c":9007199254740991,"e":0.12345678901234567,"g":1e12345678901234567}'
  parsed <- zujson::json_parse(mark(x))
  expect_identical(parsed$a, "\0369007199254740993")
  expect_identical(parsed$s, "12345678901234567")
  expect_identical(parsed$t, "a\"9999999999999999")
  expect_identical(parsed$b, list(1.5, "\036-9223372036854775808"))
  expect_identical(parsed$c, 9007199254740991)
  # Digits after a point or in an exponent are not an integer of their own.
  expect_identical(parsed$e, zujson::json_parse('{"e":0.12345678901234567}')$e)
  expect_identical(parsed$g, Inf)
  all <- zujson::json_parse(mark('{"v":1.50,"w":[1E+2,-0.0],"k":"1.50"}', all = TRUE))
  expect_identical(all, list(v = "\0361.50", w = c("\0361E+2", "\036-0.0"), k = "1.50"))
})

test_that("int64 = \"integer64\" without bit64 is a classed error naming it", {
  local_mocked_bindings(has_bit64 = function() FALSE)
  tbl <- lake_open(fixture_table("zl-basic"))
  for (f in list(function() lake_files(tbl, int64 = "integer64"), function() lake_summary(tbl, int64 = "integer64"),
                 function() lake_transactions(tbl, int64 = "integer64"))) {
    err <- tryCatch(f(), error = identity)
    expect_s3_class(err, "zulake_error_argument")
    expect_match(conditionMessage(err), "bit64", fixed = TRUE)
  }
  expect_identical(nrow(lake_files(tbl)), 2L)
})

test_that("a 64-bit field that is not a whole number is a corrupt log", {
  # (A one-element array is not here: zujson gives it as the number.)
  for (value in c('\\"x\\"', "1.5", "true", "{}")) {
    lines <- c(raw_header(), raw_add("a.parquet", stats = sprintf('{\\"numRecords\\":%s}', value)))
    tbl <- lake_open(raw_table(lines))
    expect_error(lake_files(tbl), class = "zulake_error_corrupt_log")
    expect_error(lake_count(tbl), class = "zulake_error_corrupt_log")
    expect_identical(nrow(lake_files(tbl, stats = FALSE)), 1L)
  }
  lines <- c(raw_header(), raw_add("a.parquet", stats = '{\\"nullCount\\":{\\"id\\":2.5}}'))
  expect_error(lake_files(lake_open(raw_table(lines))), class = "zulake_error_corrupt_log")
  lines <- c(raw_header(), raw_add("a.parquet", size = "100", extra = ',"modificationTime2":1'))
  lines[3] <- sub('"modificationTime":0', '"modificationTime":"soon"', lines[3], fixed = TRUE)
  expect_error(lake_files(lake_open(raw_table(lines))), class = "zulake_error_corrupt_log")
})

test_that("a time field that is not a whole number is a corrupt log", {
  lines <- c(raw_header(), raw_add("a.parquet"), '{"txn":{"appId":"a","version":1,"lastUpdated":1.5}}')
  expect_error(lake_transactions(lake_open(raw_table(lines))), class = "zulake_error_corrupt_log")
})

test_that("time text is range-checked by one parser, at open and in filters (#53)", {
  bad <- list(
    date = c("2024-02-30", "2023-02-29", "2024-13-01", "2024-00-10", "2024-04-31"),
    timestamp = c("2024-01-01 24:00:00", "2024-01-01 12:60:00", "2024-01-01 12:00:60", "2024-01-01 12:00:61",
                  "2024-01-01 25:61:61", "2024-01-01 12:00:00+99:99", "2024-01-01 12:00:00+01:60",
                  "2024-01-01 12:00:00+19:00", "2024-02-30 00:00:00"),
    timestamp_ntz = c("2024-01-01 24:00:00", "2024-01-01 12:60:00", "2024-01-01 12:00:61", "2024-02-30 00:00:00")
  )
  good <- list(
    date = c("2024-02-29", "2024-12-31", "1970-01-01"),
    timestamp = c("2024-01-01 23:59:59", "2024-01-01 00:00:00", "2024-01-01T23:59:59.999999Z",
                  "2024-01-01 12:00:00+18:00", "2024-01-01 12:00:00-05:30"),
    timestamp_ntz = c("2024-01-01 23:59:59.999999", "2024-02-29 00:00:00")
  )
  # Every table has the feature timestamp_ntz needs (#120).
  ntz <- protocol_line(3L, 7L, "timestampNtz", "timestampNtz")
  for (type in names(bad)) {
    for (x in bad[[type]]) {
      expect_false(partition_value_ok(x, type), label = paste(type, x))
      expect_true(is.na(if (type == "date") parse_date_text(x) else parse_time_text(x, zone = type == "timestamp")),
                  label = paste(type, x))
      path <- hand_table(c(ntz, metadata_line(c(id = "long", p = type), partition = "p"),
                           add_line("a.parquet", partition = list(p = x))))
      expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
      # As a filter literal, against a column of the same type.
      tbl <- lake_open(hand_table(c(ntz, metadata_line(c(id = "long", p = type), partition = "p"),
                                    add_line("a.parquet", partition = list(p = good[[type]][1L])))))
      expect_error(lake_files(tbl, filter = p > x), class = "zulake_error_filter", label = paste(type, x))
    }
    for (x in good[[type]]) {
      expect_true(partition_value_ok(x, type), label = paste(type, x))
      path <- hand_table(c(ntz, metadata_line(c(id = "long", p = type), partition = "p"),
                           add_line("a.parquet", partition = list(p = x))))
      expect_identical(nrow(lake_files(lake_open(path))), 1L, label = paste(type, x))
    }
  }
})

test_that("timestamp text becomes the double qio reads for the same microseconds (#54)", {
  withr::local_seed(54)
  us <- c(-1, 1, -1.5e6, -999999, 999999, -86400e6 + 1, sample(-2e6:2e6, 200),
          round(runif(50, -2^53, 2^53)), 2^53 - 1, -(2^53 - 1), -62135596800000000)
  text <- us_time_text(us)
  want <- qio_read_us(us)
  got <- as.numeric(parse_time_text(text, zone = TRUE))
  expect_identical(got, want)
  expect_identical(as.numeric(parse_time_text(text, zone = FALSE)), want)
  expect_identical(as.numeric(parse_time_text(paste0(sub(" ", "T", text), "Z"))), want)
  # Past 2^53 microseconds the count is rounded once, as a 64-bit count
  # converted to double is: 253402300799999999 is 253402300800000000.
  expect_identical(as.numeric(parse_time_text("9999-12-31 23:59:59.999999")), 253402300800)
  # With an offset: the same instant.
  shifted <- us_time_text(us + 3600e6)
  expect_identical(as.numeric(parse_time_text(paste0(shifted, "+01:00"))), want)
  # A filter on the column, and on a partition, finds the value qio reads.
  path <- file.path(withr::local_tempdir(), "t")
  dir.create(path)
  ts_us <- c(-1, 0, 1, -1.5e6)
  qio::write_parquet(data.frame(id = as.numeric(seq_along(ts_us)), ts = .POSIXct(ts_us / 1e6, tz = "UTC")),
                     file.path(path, "a.parquet"))
  write_commit(path, 0, c(protocol_line(), metadata_line(c(id = "double", ts = "timestamp")),
                          add_line("a.parquet", size = file.size(file.path(path, "a.parquet")))))
  tbl <- lake_open(path)
  expect_identical(lake_read(tbl, filter = ts == "1969-12-31 23:59:59.999999")$id, 1)
  expect_identical(lake_read(tbl, filter = ts <= "1969-12-31 23:59:59.999999")$id, c(1, 4))
  expect_identical(lake_read(tbl, filter = ts != "1969-12-31 23:59:59.999999")$id, c(2, 3, 4))
  expect_identical(lake_read(tbl, filter = ts %in% "1969-12-31 23:59:58.5")$id, 4)
  part <- hand_table(c(protocol_line(), metadata_line(c(id = "long", p = "timestamp"), partition = "p"),
                       add_line("a.parquet", partition = list(p = "1969-12-31 23:59:59.999999"))))
  expect_identical(nrow(lake_files(lake_open(part), filter = p == as.POSIXct(-1e-6, origin = "1970-01-01", tz = "UTC"))), 1L)
  expect_identical(nrow(lake_files(lake_open(part), filter = p == -1e-6)), 1L)
})

test_that("a string that starts with U+001E is a string, never a marked number (#56)", {
  for (big in c(FALSE, TRUE)) {
    path <- file.path(withr::local_tempdir(), "t")
    dir.create(path)
    s <- c("\x1e12", "\x1eabc", "plain")
    qio::write_parquet(data.frame(s = s), file.path(path, "a.parquet"))
    stats <- zujson::json_write(list(numRecords = 3L, minValues = list(s = "\x1e12"), maxValues = list(s = "plain"),
                                     nullCount = list(s = 0L)), auto_unbox = TRUE)
    add <- list(path = "a.parquet", partitionValues = list(p = "\x1e77"), size = file.size(file.path(path, "a.parquet")),
                modificationTime = 0, dataChange = TRUE, stats = stats)
    info <- list(timestamp = 0, operation = "WRITE", note = "\x1e123", `\x1ekey` = "v",
                 n = if (big) bit64::as.integer64("9007199254740993") else 5)
    lines <- c(json_line(list(commitInfo = info)), protocol_line(),
               metadata_line(c(s = "string", p = "string"), partition = "p"), json_line(list(add = add)))
    # zujson writes U+001E as \u001e; a writer may write \u001E.
    lines[4L] <- sub("\\\\u001e77", "\\\\u001E77", lines[4L])
    if (big) skip_if_not_installed("bit64")
    write_commit(path, 0, lines)
    tbl <- lake_open(path)
    label <- if (big) "with a number past 2^53" else "without one"
    expect_identical(lake_files(tbl)$min[[1L]]$s, "\x1e12", label = label)
    expect_identical(lake_files(tbl)$max[[1L]]$s, "plain", label = label)
    expect_identical(lake_files(tbl)$action[[1L]]$partitionValues$p, "\x1e77", label = label)
    expect_identical(lake_files(tbl)$partition[[1L]]$p, "\x1e77", label = label)
    actions <- lake_actions(tbl, 0, int64 = if (big) "integer64" else "double")
    expect_identical(actions$action[[which(actions$type == "add")]]$partitionValues$p, "\x1e77", label = label)
    expect_identical(lake_partitions(tbl)$p, "\x1e77", label = label)
    ci <- lake_history(tbl, int64 = if (big) "integer64" else "double")$commit_info[[1L]]
    expect_identical(ci$note, "\x1e123", label = label)
    expect_identical(ci[["\x1ekey"]], "v", label = label)
    expect_identical(nrow(lake_files(tbl, filter = s == "\x1e12")), 1L, label = label)
    expect_identical(nrow(lake_files(tbl, filter = p == "\x1e77")), 1L, label = label)
    expect_identical(lake_read(tbl, filter = s == "\x1e12")$s, "\x1e12", label = label)
    expect_identical(lake_read(tbl, filter = s %in% "\x1eabc")$s, "\x1eabc", label = label)
    expect_identical(lake_read(tbl, filter = s < "0")$s, c("\x1e12", "\x1eabc"), label = label)
  }
})

test_that("a long string before a number past 2^53 leaves it exact, and a scan failure is an error (#57)", {
  skip_if_not_installed("bit64")
  # 5e6 is the length that once passed PCRE's match limit (#57); CRAN runs
  # the shorter two.
  for (n in test_iterations(c(1e3, 1e6, 5e6), c(1e3, 1e6))) {
    path <- hand_table(c(
      json_line(list(commitInfo = list(timestamp = 0, userMetadata = strrep("x", n)))),
      protocol_line(), metadata_line(), add_line("a.parquet"),
      '{"txn":{"appId":"a","version":9007199254740993}}'
    ))
    expect_identical(as.character(lake_transactions(lake_open(path), int64 = "integer64")$version), "9007199254740993",
                     label = n)
    expect_error(lake_transactions(lake_open(path)), class = "zulake_error_int64")
  }
  # Escapes all through a long string, too.
  long <- paste0('{"commitInfo":{"timestamp":0,"userMetadata":"', strrep('\\"', 2e6), '"}}')
  path <- hand_table(c(long, protocol_line(), metadata_line(), '{"txn":{"appId":"a","version":9007199254740993}}'))
  expect_identical(as.character(lake_transactions(lake_open(path), int64 = "integer64")$version), "9007199254740993")
  # PCRE failing (its match limit) is a corrupt log, never unmarked digits.
  local_mocked_bindings(json_tokens = function(pattern, text) {
    warning("PCRE error\n\t'match limit exceeded'")
    gregexpr(pattern, text, perl = TRUE)
  })
  expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
})

test_that("double and float partition values inf, -inf and NaN read as deltalake writes them (#67)", {
  # zl-inf-partitions: deltalake 1.7.0 writes "inf", "-inf" and "NaN".
  tbl <- lake_open(fixture_table("zl-inf-partitions"))
  expect_oracle(replay_files_frame(tbl, "path"), "zl-inf-partitions", 0, "add_actions")
  rows <- lake_read(tbl)
  expect_read_oracle(rows, "zl-inf-partitions", 0)
  expect_identical(rows$f64[order(rows$id)], c(Inf, -Inf, NaN, 1.5))
  expect_identical(lake_read(tbl, filter = f64 == Inf)$id, 0)
  expect_identical(sort(lake_read(tbl, filter = f32 < 0 | is.nan(f64))$id), c(0, 2))
  expect_identical(nrow(lake_files(tbl, filter = f64 == -Inf)), 1L)
  # Every spelling of an infinity or NaN Rust's f64 parser takes, in any
  # case and with a sign; nothing more.
  ok <- c("inf", "-inf", "+inf", "INF", "Inf", "infinity", "-Infinity", "+INFINITY", "nan", "NaN", "-nan", "+NAN",
          "Infinity", "-Infinity", "1.5", "-0", "1e10")
  bad <- c("in", "infin", "infinit", "infinityy", "na", "nann", " inf", "inf ", "--inf", "+-inf", "0x10", "1e")
  for (type in c("double", "float")) {
    for (x in ok) expect_true(zulake:::partition_value_ok(x, type), label = paste(type, x))
    for (x in bad) expect_false(zulake:::partition_value_ok(x, type), label = paste(type, x))
  }
  meta <- metadata_line(c(id = "long", p = "double"), partition = "p")
  for (x in ok) {
    t <- lake_open(hand_table(c(protocol_line(), meta, add_line("a.parquet", list(p = x)))))
    want <- switch(tolower(sub("^[+-]", "", x)), inf = , infinity = if (startsWith(x, "-")) -Inf else Inf,
                   nan = NaN, as.numeric(x))
    expect_identical(lake_files(t)$partition[[1L]]$p, want, label = x)
  }
})

test_that("a sum past 2^63 - 1 in integer64 is a classed error, not NA (#92)", {
  skip_if_not_installed("bit64")
  half <- "4611686018427387904"
  stats <- sprintf('{\\"numRecords\\":%s}', half)
  tbl <- lake_open(raw_table(c(raw_header(), raw_add("a.parquet", stats = stats, size = half),
                               raw_add("b.parquet", stats = stats, size = half))))
  expect_warning(expect_error(lake_summary(tbl, int64 = "integer64"), class = "zulake_error_int64"), NA)
  # One below the limit sums.
  below <- "4611686018427387903"
  stats <- sprintf('{\\"numRecords\\":%s}', below)
  tbl <- lake_open(raw_table(c(raw_header(), raw_add("a.parquet", stats = stats, size = below),
                               raw_add("b.parquet", stats = stats, size = half))))
  s <- lake_summary(tbl, int64 = "integer64")
  expect_identical(as.character(s$bytes), "9223372036854775807")
  expect_identical(as.character(s$records), "9223372036854775806")
})

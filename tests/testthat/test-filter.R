# Filters (design sections 5 and 6, D8): lake_files(filter =) and
# lake_partitions(filter =) on partition values and statistics, and
# lake_read(filter =) on rows. The oracles: R's evaluation of the same
# expression on deltalake's partition values, and on deltalake's full read.

test_that("partition filters keep exactly the files R's evaluation on deltalake's partition values keeps", {
  withr::local_seed(20261126)
  withr::local_collate("C")
  filter_tables <- c("zl-partitioned", "delta-2.2.0-partitioned-types", "delta-0.8.0-partitioned",
                     "delta-0.8.0-null-partition", "table_with_column_mapping")
  for (table in filter_tables) {
    v <- max(oracle_versions(table))
    tbl <- lake_open(fixture_table(table))
    parts <- oracle_partition_frame(table, v)
    data_cols <- setdiff(lake_schema(tbl)$name, names(parts))
    n_checked <- 0L
    for (i in seq_len(150)) {
      expr <- random_filter(parts, data_cols)
      expected <- oracle_filter_paths(expr, parts, data_cols)
      got <- eval(bquote(lake_files(tbl, filter = .(expr), stats = FALSE)))$path
      if (length(intersect(all.vars(expr), data_cols))) {
        # Statistics may rule out more; test-filter's lake_read() tests show
        # those files hold no matching row.
        expect_true(all(got %in% expected), label = paste(table, deparse(expr)))
        expected <- got
      } else {
        expect_identical(got, expected, label = paste(table, deparse(expr)))
      }
      pv <- eval(bquote(lake_partitions(tbl, filter = .(expr))))
      expect_identical(nrow(pv), nrow(unique(parts[parts$path %in% expected, names(parts) != "path", drop = FALSE])))
      n_checked <- n_checked + length(expected)
    }
    expect_gt(n_checked, 0L)
  }
})

test_that("filters see values from the calling environment, and columns win over them", {
  tbl <- lake_open(fixture_table("zl-partitioned"))
  all <- lake_files(tbl, stats = FALSE)
  p_int <- 99L
  wanted <- 1L
  f <- function(x) lake_files(tbl, filter = p_int == x, stats = FALSE)$path
  expect_identical(f(1L), lake_files(tbl, filter = p_int == wanted, stats = FALSE)$path)
  expect_identical(length(f(1L)), 2L)
  expect_identical(lake_files(tbl, filter = p_int %in% c(1L, 3L), stats = FALSE)$path, all$path[c(2, 3, 4)])
  expect_identical(lake_files(tbl, filter = p_date == as.Date("2024-01-03"), stats = FALSE)$path, all$path[5])
  expect_identical(lake_files(tbl, filter = p_date == "2024-01-03", stats = FALSE)$path, all$path[5])
  expect_identical(lake_files(tbl, filter = is.na(p_str), stats = FALSE)$path, all$path[1])
  expect_identical(lake_files(tbl, filter = p_str == "café", stats = FALSE)$path, all$path[4])
  expect_identical(lake_files(tbl, filter = p_str == "x/y=z%", stats = FALSE)$path, all$path[5])
  # A comparison with a data column rules files out by their statistics.
  max_value <- vapply(lake_files(tbl)$max, function(m) m$value, 0)
  expect_identical(lake_files(tbl, filter = value > 1e9, stats = FALSE)$path, character())
  expect_identical(lake_files(tbl, filter = value >= 2, stats = FALSE)$path, all$path[max_value >= 2])
  expect_identical(lake_files(tbl, filter = value < 1e9 & p_int == 4L, stats = FALSE)$path, all$path[1])
  expect_identical(nrow(lake_files(tbl, filter = !(value > 0 | !is.na(p_int) | is.na(p_int)), stats = FALSE)), 0L)
  # A column name with spaces, in backticks.
  tbl <- lake_open(fixture_table("table_with_column_mapping"))
  expect_identical(nrow(lake_files(tbl, filter = `Company Very Short` == "BME")), 1L)
  expect_identical(lake_partitions(tbl, filter = `Company Very Short` != "BME")[[1L]], "BMS")
})

test_that("a filter outside the pruning subset is a classed error", {
  tbl <- lake_open(fixture_table("zl-partitioned"))
  bad <- list(
    quote(nchar(p_str) > 2),
    quote(p_int + 1 == 2),
    quote(p_int == p_date + 1),
    quote(grepl("a", p_str)),
    quote(p_int),
    quote(p_int == 1 && p_str == "a"),
    quote(p_int %in% c(1, 2) & nchar(p_str) > 0),
    quote(1 == 2),
    quote(p_int == no_such_value_anywhere),
    quote(is.na(p_int + 1)),
    quote(!p_int),
    "p_int == 1",
    1,
    quote(p_int == mean)
  )
  for (expr in bad) {
    err <- tryCatch(eval(bquote(lake_files(tbl, filter = .(expr)))), error = identity)
    expect_s3_class(err, "zulake_error_filter")
    expect_s3_class(err, "zulake_error")
    err <- tryCatch(eval(bquote(lake_partitions(tbl, filter = .(expr)))), error = identity)
    expect_s3_class(err, "zulake_error_filter")
  }
  expect_match(conditionMessage(tryCatch(lake_files(tbl, filter = nchar(p_str) > 2), error = identity)),
               "nchar(p_str) > 2", fixed = TRUE)
})

test_that("filters work on a table without partition columns and on a table without files", {
  tbl <- lake_open(fixture_table("zl-basic"))
  files <- lake_files(tbl)
  max_id <- vapply(files$max, function(m) m$id, 0)
  expect_identical(lake_files(tbl, filter = id > 100)$path, files$path[max_id > 100])
  expect_identical(lake_files(tbl, filter = id >= 3)$path, files$path[max_id >= 3])
  expect_identical(dim(lake_partitions(tbl)), c(0L, 0L))
  path <- hand_table(c(protocol_line(), metadata_line(c(id = "long", p = "integer"), partition = "p")))
  tbl <- lake_open(path)
  expect_identical(nrow(lake_files(tbl, filter = p == 1)), 0L)
  expect_identical(names(lake_partitions(tbl, filter = p == 1)), "p")
})

# ---- Stage 4: rows, statistics and exact comparison --------------------------

test_that("lake_read(filter = f) equals the full read subset in R, and no pruned file has a matching row", {
  withr::local_seed(20261127)
  withr::local_collate("C")
  tables <- c("zl-partitioned", "zl-basic", "delta-2.2.0-partitioned-types", "delta-0.8.0-partitioned",
              "delta-0.8.0-null-partition", "zl-types", "zl-checkpoint", "checkpoint-v2-table",
              "table_failed_last_checkpoint_update", "table_with_edge_timestamps")
  pruned <- 0L
  for (table in tables) {
    tbl <- lake_open(fixture_table(table))
    full <- suppressWarnings(lake_read(tbl))
    pieces <- suppressWarnings(read_each_file(tbl))
    paths <- lake_files(tbl, stats = FALSE)$path
    data <- full[!vapply(full, is.list, NA)]
    for (i in seq_len(25)) {
      expr <- random_row_filter(data)
      label <- paste(table, paste(deparse(expr), collapse = " "))
      got <- tryCatch(suppressWarnings(eval(bquote(lake_read(tbl, filter = .(expr))))), zulake_error_filter = identity)
      if (inherits(got, "zulake_error_filter")) {
        # A double with no exact 15-digit form, compared with an exact
        # column; R would compare it as a double.
        expect_match(conditionMessage(got), "write it as text", fixed = TRUE, label = label)
        next
      }
      expect_identical(got, r_subset(full, expr), label = label)
      kept <- eval(bquote(lake_files(tbl, filter = .(expr), stats = FALSE)))$path
      for (k in which(!paths %in% kept)) {
        pruned <- pruned + 1L
        expect_identical(nrow(r_subset(pieces[[k]], expr)), 0L, label = paste(label, paths[k]))
      }
    }
  }
  expect_gt(pruned, 50L)
})

test_that("partition values are compared as their Delta type, exactly as deltalake typed them", {
  withr::local_collate("C")
  for (case in inspect_cases()) {
    tbl <- case_snapshot(case)
    pcols <- lake_partition_columns(tbl)
    if (!length(pcols)) next
    parts <- oracle_partition_frame(case$table, case$version)
    for (col in pcols) {
      for (v in unique(parts[[col]])) {
        expr <- if (is.na(v)) bquote(is.na(.(as.symbol(col)))) else bquote(.(as.symbol(col)) == .(v))
        got <- eval(bquote(lake_files(tbl, filter = .(expr), stats = FALSE)))$path
        want <- parts$path[if (is.na(v)) is.na(parts[[col]]) else parts[[col]] %in% v]
        expect_identical(got, want, label = paste(case$table, case$version, deparse(expr)))
      }
    }
  }
})

test_that("string statistics compare in UTF-8 byte order whatever the collation", {
  stats <- function(lo, hi) sprintf('{\\"numRecords\\":2,\\"minValues\\":{\\"s\\":\\"%s\\"},\\"maxValues\\":{\\"s\\":\\"%s\\"},\\"nullCount\\":{\\"s\\":0}}', lo, hi)
  tbl <- lake_open(raw_table(c(raw_header(c(s = "string")), raw_add("a.parquet", stats = stats("B", "a")),
                               raw_add("b.parquet", stats = stats("a", "z")))))
  for (collate in c("C", "en_US.UTF-8")) {
    withr::with_collate(collate, {
      # "B" (0x42) < "b" (0x62) < "a"? no: "a" (0x61) < "b", so b.parquet may hold "b" and a.parquet not.
      expect_identical(lake_files(tbl, filter = s == "b")$path, "b.parquet")
      expect_identical(lake_files(tbl, filter = s < "C")$path, "a.parquet")
      # "é" (0xC3 0xA9) sorts after "z" in bytes, before it in most collations.
      expect_identical(lake_files(tbl, filter = s == "é")$path, character())
      expect_identical(lake_files(tbl, filter = s > "é")$path, character())
      expect_identical(lake_files(tbl, filter = s < "é")$path, c("a.parquet", "b.parquet"))
    })
  }
})

test_that("a string maximum is never taken as exact: it may be a truncated prefix", {
  stats <- '{\\"numRecords\\":2,\\"minValues\\":{\\"s\\":\\"abc\\"},\\"maxValues\\":{\\"s\\":\\"abc\\"},\\"nullCount\\":{\\"s\\":0}}'
  tbl <- lake_open(raw_table(c(raw_header(c(s = "string")), raw_add("a.parquet", stats = stats))))
  keeps <- function(expr) nrow(eval(bquote(lake_files(tbl, filter = .(expr))))) == 1L
  expect_true(keeps(quote(s == "abcd")))
  expect_true(keeps(quote(s > "abc")))
  expect_true(keeps(quote(s >= "abc\U0010FFFF")))
  expect_true(keeps(quote(s != "abc")))
  expect_true(keeps(quote(!(s %in% "abc"))))
  expect_false(keeps(quote(s > "abd")))
  expect_false(keeps(quote(s == "abd")))
  expect_false(keeps(quote(s < "abc")))
  expect_false(keeps(quote(s == "ab")))
  # On a fixture: a maximum cut short in the log still finds the row.
  path <- local_fixture_copy("zl-basic")
  tbl <- lake_open(path)
  full <- lake_read(tbl)
  top <- max(full$label)
  f <- lake_files(tbl)
  i <- which(vapply(f$max, function(m) identical(m$label, top), NA))[1L]
  log <- file.path(path, "_delta_log", list.files(file.path(path, "_delta_log"), pattern = "json$"))
  for (file in log) {
    lines <- readLines(file, warn = FALSE)
    hit <- grepl(f$path[i], lines, fixed = TRUE) & grepl('"add"', lines, fixed = TRUE)
    lines[hit] <- sub(sprintf('\\\\"label\\\\":\\\\"%s\\\\"}', top), sprintf('\\\\"label\\\\":\\\\"%s\\\\"}', substr(top, 1L, 1L)),
                      lines[hit])
    writeLines(lines, file)
  }
  tbl <- lake_open(path)
  expect_identical(lake_files(tbl)$max[[i]]$label, substr(top, 1L, 1L))
  expect_identical(lake_read(tbl, filter = label == top), full[full$label == top, , drop = FALSE], ignore_attr = TRUE)
})

test_that("decimal statistics are bounds only when exact: missing, past precision 15, or past the scale they are unknown", {
  stats <- function(lo, hi) sprintf('{\\"numRecords\\":1,\\"minValues\\":{\\"d\\":%s},\\"maxValues\\":{\\"d\\":%s},\\"nullCount\\":{\\"d\\":0}}', lo, hi)
  kept <- function(type, lo, hi, expr) {
    tbl <- lake_open(raw_table(c(raw_header(c(d = type)), raw_add("a.parquet", stats = stats(lo, hi)))))
    nrow(eval(bquote(lake_files(tbl, filter = .(expr))))) == 1L
  }
  expect_false(kept("decimal(10,2)", "1.25", "2.50", quote(d > 2.5)))
  expect_true(kept("decimal(10,2)", "1.25", "2.50", quote(d >= 2.5)))
  expect_false(kept("decimal(10,2)", "1.25", "2.50", quote(d > "2.50")))
  expect_true(kept("decimal(10,2)", "1.25", "2.50", quote(d > "2.4999999999999999999999")))
  expect_false(kept("decimal(10,2)", "1.25", "2.50", quote(d < 1.25)))
  # More fraction digits than the scale: written through a double, so the
  # column's 2.51 can be a maximum of 2.5099999999999998.
  expect_true(kept("decimal(10,2)", "1.25", "2.5099999999999998", quote(d >= 2.51)))
  expect_true(kept("decimal(10,2)", "1.2500000000000002", "2.50", quote(d <= 1.25)))
  expect_false(kept("decimal(10,2)", "1.25", "2.51", quote(d > 2.51)))
  # Precision past 15: never a bound.
  expect_true(kept("decimal(16,2)", "1.25", "2.50", quote(d > 2.5)))
  expect_true(kept("decimal(38,18)", "1.25", "2.50", quote(d > 100)))
  # Missing statistics.
  tbl <- lake_open(raw_table(c(raw_header(c(d = "decimal(10,2)")), raw_add("a.parquet"))))
  expect_identical(nrow(lake_files(tbl, filter = d > 100)), 1L)
  # zl-types' decimal(38,18) statistic, written in exponent form, keeps its file.
  tbl <- lake_open(fixture_table("zl-types"))
  expect_true(grepl("e+19", lake_files(tbl, stats = FALSE)$action[[1L]]$stats, fixed = TRUE))
  expect_identical(nrow(suppressWarnings(lake_files(tbl, filter = dec38 > 1e30))), 1L)
})

test_that("long statistics and partition values compare exactly at 64 bits", {
  skip_if_not_installed("bit64")
  stats <- function(lo, hi) sprintf('{\\"numRecords\\":1,\\"minValues\\":{\\"id\\":%s},\\"maxValues\\":{\\"id\\":%s},\\"nullCount\\":{\\"id\\":0}}', lo, hi)
  tbl <- lake_open(raw_table(c(
    raw_header(c(id = "long", p = "long"), partition = "p"),
    raw_add("a.parquet", stats = stats("-9223372036854775808", "9007199254740993"), partition = '{"p":"3"}'),
    raw_add("b.parquet", stats = stats("9007199254740994", "9223372036854775807"), partition = '{"p":"9223372036854775807"}')
  )))
  paths <- function(expr, int64 = "integer64") {
    suppressWarnings(eval(bquote(lake_files(tbl, filter = .(expr), stats = FALSE, int64 = .(int64)))))$path
  }
  expect_identical(paths(quote(id == "9007199254740993")), "a.parquet")
  expect_identical(paths(quote(id > "9007199254740993")), "b.parquet")
  expect_identical(paths(quote(id >= bit64::as.integer64("9007199254740994"))), "b.parquet")
  expect_identical(paths(quote(id < "-9223372036854775807")), "a.parquet")
  expect_identical(paths(quote(id > "9223372036854775806")), "b.parquet")
  expect_identical(paths(quote(id > "9223372036854775807")), character())
  expect_identical(paths(quote(p > "9223372036854775806")), "b.parquet")
  # The double 9223372036854775807 is 2^63, past every long.
  expect_identical(paths(quote(p >= 9223372036854775807)), character())
  expect_identical(paths(quote(p == "9223372036854775807")), "b.parquet")
  # bit64 would turn 3.5 into 3; zulake never hands it a fraction.
  expect_false(bit64::as.integer64(3) < 3.5)
  for (int64 in c("double", "integer64")) {
    expect_identical(paths(quote(p < 3.5), int64), "a.parquet")
    expect_identical(paths(quote(p > 2.5 & p < 3.5), int64), "a.parquet")
    expect_identical(paths(quote(p %in% c(3.5, 2)), int64), character())
  }
  # And rows: a long column read as integer64, filtered with a fraction.
  r <- lake_read(lake_open(fixture_table("zl-basic")), int64 = "integer64")
  cut <- sort(as.numeric(as.character(r$id)))[2L] + 0.5
  got <- lake_read(lake_open(fixture_table("zl-basic")), filter = id < cut, int64 = "integer64")
  expect_identical(sort(as.character(got$id)), sort(as.character(r$id[as.numeric(as.character(r$id)) < cut])))
  expect_gt(nrow(got), 0L)
})

test_that("float and timestamp statistics are widened by what writers round away; NaN is possible in floats", {
  stats <- function(col, lo, hi, nulls = 0) sprintf('{\\"numRecords\\":2,\\"minValues\\":{\\"%s\\":%s},\\"maxValues\\":{\\"%s\\":%s},\\"nullCount\\":{\\"%s\\":%s}}', col, lo, col, hi, col, nulls)
  kept <- function(type, lo, hi, expr) {
    tbl <- lake_open(raw_table(c(raw_header(c(x = type)), raw_add("a.parquet", stats = stats("x", lo, hi)))))
    nrow(eval(bquote(lake_files(tbl, filter = .(expr))))) == 1L
  }
  # The float nearest 0.1 is 0.100000001490116..., above the double 0.1.
  expect_true(kept("float", "0.1", "0.1", quote(x > 0.1)))
  expect_false(kept("double", "0.1", "0.1", quote(x > 0.1)))
  expect_false(kept("float", "0.1", "0.1", quote(x > 0.1000001)))
  ts <- '\\"2024-01-01T00:00:00.000Z\\"'
  expect_true(kept("timestamp", ts, ts, quote(x > as.POSIXct("2024-01-01 00:00:00.0005", tz = "UTC"))))
  expect_false(kept("timestamp", ts, ts, quote(x > as.POSIXct("2024-01-01 00:00:00.002", tz = "UTC"))))
  expect_false(kept("timestamp", ts, ts, quote(x > "2024-01-01 00:00:01")))
  # NaN is not a null and statistics do not count it.
  expect_true(kept("double", "1", "1", quote(!(x %in% 1))))
  expect_true(kept("double", "1", "1", quote(is.na(x))))
  expect_false(kept("long", "1", "1", quote(!(x %in% 1))))
  expect_false(kept("long", "1", "1", quote(is.na(x))))
  expect_false(kept("double", "1", "1", quote(x != 1)))
})

test_that("null counts decide is.na() and comparisons; a file without statistics is always kept", {
  stats <- function(n, nulls) sprintf('{\\"numRecords\\":%d,\\"nullCount\\":{\\"id\\":%d}}', n, nulls)
  tbl <- lake_open(raw_table(c(raw_header(c(id = "long")),
                               raw_add("all-null.parquet", stats = stats(2, 2)),
                               raw_add("no-null.parquet", stats = stats(2, 0)),
                               raw_add("empty.parquet", stats = stats(0, 0)),
                               raw_add("none.parquet"))))
  expect_identical(lake_files(tbl, filter = is.na(id))$path, c("all-null.parquet", "none.parquet"))
  expect_identical(lake_files(tbl, filter = !is.na(id))$path, c("no-null.parquet", "none.parquet"))
  expect_identical(lake_files(tbl, filter = id > 0)$path, c("no-null.parquet", "none.parquet"))
  expect_identical(lake_files(tbl, filter = id %in% c(1, NA))$path, c("all-null.parquet", "no-null.parquet", "none.parquet"))
  expect_identical(lake_files(tbl, filter = id == NA)$path, character())
  expect_identical(lake_files(tbl, filter = !(id == NA))$path, character())
})

test_that("the exact comparator agrees with a second implementation on random decimal text", {
  withr::local_seed(20261128)
  a <- vapply(seq_len(400), function(i) random_decimal_text(), "")
  b <- c(vapply(seq_len(300), function(i) random_decimal_text(), ""), sample(a, 100))
  got <- exact_cmp(exact_parse(a), exact_parse(b))
  want <- vapply(seq_along(a), function(i) reference_cmp(a[i], b[i]), 0L)
  expect_identical(got, want)
  expect_true(any(want == 0L))
  # Spellings of one value.
  same <- list(c("12.30", "12.3", "+12.3", "1.23e1", "1.23E+1", "012.300", "123e-1"),
               c("0", "-0", "+0.000", "0e5"),
               c("12345678901234570000", "1.234567890123457e+19"))
  for (s in same) {
    p <- exact_parse(s)
    expect_identical(exact_cmp(p, keys_subset(p, 1L)), rep(0L, length(s)))
  }
  expect_identical(exact_cmp(exact_parse(c("-Inf", "Inf", "1e400", "-1e400", NA)), exact_parse("Inf")),
                   c(-1L, 0L, -1L, -1L, NA))
})

test_that("filter values become exact text by the documented rules", {
  expr <- quote(x > v)
  keys_text <- function(v) {
    k <- literal_keys(v, "exact", "long", expr)$keys
    vapply(seq_along(k$sign), function(i) paste(k$sign[i], k$exp[i], k$digits[i]), "")
  }
  same_as <- function(v, text) expect_identical(keys_text(v), keys_text(text), label = deparse(v))
  same_as(0.1, "0.1")
  same_as(12.3, "12.3")
  same_as(2^60, "1152921504606846976")
  same_as(1e20, "100000000000000000000")
  same_as(-0, "0")
  same_as(5L, "5")
  same_as(TRUE, "1")
  expect_identical(literal_keys(c(Inf, -Inf), "exact", "long", expr)$keys, exact_parse(c("Inf", "-Inf")))
  same_as(factor("7.5"), "7.5")
  expect_identical(literal_keys(c(NA, NaN, 1), "exact", "long", expr)$nan, c(FALSE, TRUE, FALSE))
  expect_true(all(is.na(literal_keys(c(NA, NaN), "exact", "long", expr)$keys$sign)))
  for (bad in list(1 / 3, 0.1 + 0.2, "1.2.3", " 1", "1e", "0x10", "Inf")) {
    expect_error(literal_keys(bad, "exact", "long", expr), class = "zulake_error_filter", label = deparse(bad))
  }
  expect_match(conditionMessage(tryCatch(literal_keys(1 / 3, "exact", "long", expr), error = identity)),
               "write it as text", fixed = TRUE)
  # Number columns.
  num <- function(v, type = "double") literal_keys(v, "number", type, expr)$keys
  expect_identical(num("1.5e3"), 1500)
  expect_identical(num(as.Date("1970-01-11"), "date"), 10)
  expect_identical(num("1970-01-11", "date"), 10)
  expect_identical(num("1970-01-01 00:00:01.5", "timestamp"), 1.5)
  expect_identical(num("1970-01-01T01:00:00+01:00", "timestamp"), 0)
  expect_identical(num(TRUE, "boolean"), 1)
  for (bad in list(list("TRUE", "boolean"), list("tomorrow", "date"), list(Sys.time(), "date"),
                   list(Sys.Date(), "timestamp"), list("1,5", "double"))) {
    expect_error(literal_keys(bad[[1L]], "number", bad[[2L]], expr), class = "zulake_error_filter")
  }
  skip_if_not_installed("bit64")
  same_as(bit64::as.integer64("9223372036854775807"), "9223372036854775807")
  expect_identical(num(bit64::as.integer64(5)), 5)
})

test_that("filter values arrive the same in a hostile session", {
  tbl <- lake_open(fixture_table("zl-partitioned"))
  run <- function() {
    list(
      lake_files(tbl, filter = p_int > 1.5 & p_date < "2024-01-04", stats = FALSE)$path,
      lake_files(tbl, filter = value > 12345678.25, stats = FALSE)$path,
      lake_read(tbl, filter = value %in% c(0.5, 2, 1e6) | p_str == "café")
    )
  }
  stats <- '{\\"numRecords\\":1,\\"minValues\\":{\\"t\\":\\"2024-01-05T10:00:00.123Z\\"},\\"maxValues\\":{\\"t\\":\\"2024-01-05T10:00:00.123Z\\"}}'
  ts <- lake_open(raw_table(c(raw_header(c(t = "timestamp", p = "timestamp"), partition = "p"),
                              raw_add("a.parquet", stats = stats, partition = '{"p":"2024-01-05 10:00:00.5"}'))))
  run_ts <- function() {
    f <- lake_files(ts)
    list(f$min[[1L]]$t, f$partition[[1L]]$p, nrow(lake_files(ts, filter = t > "2024-01-05 10:00:00.2")),
         nrow(lake_files(ts, filter = p < "2024-01-05T10:00:00.25Z")))
  }
  plain_ts <- run_ts()
  expect_identical(plain_ts[[1L]], as.POSIXct("2024-01-05 10:00:00.123", tz = "UTC"))
  expect_identical(plain_ts[3:4], list(0L, 0L))
  hostile_ts <- withr::with_options(list(OutDec = ",", scipen = -5, digits = 3), run_ts())
  expect_identical(hostile_ts, plain_ts)
  plain <- run()
  hostile <- withr::with_locale(c(LC_COLLATE = "C", LC_CTYPE = "C"), withr::with_options(
    list(OutDec = ",", scipen = -5, digits = 3), run()
  ))
  expect_identical(hostile, plain)
})

test_that("anything outside the pruning subset only filters rows in lake_read()", {
  tbl <- lake_open(fixture_table("zl-partitioned"))
  full <- lake_read(tbl)
  cases <- list(
    quote(nchar(p_str) > 2),
    quote(p_int + 1 == 2 | value > 1),
    quote(grepl("a", p_str) & !is.na(p_int)),
    quote(p_int %in% c(1, 2) & nchar(p_str) > 0),
    quote(TRUE),
    quote(value %% 2 == 0)
  )
  for (expr in cases) {
    got <- eval(bquote(lake_read(tbl, filter = .(expr))))
    expect_identical(got, r_subset(full, expr), label = deparse(expr))
    expect_error(eval(bquote(lake_files(tbl, filter = .(expr)))), class = "zulake_error_filter")
  }
  expect_error(lake_read(tbl, filter = p_int + 1), class = "zulake_error_filter")
  expect_error(lake_read(tbl, filter = c(TRUE, FALSE)), class = "zulake_error_filter")
  # Each file's rows are filtered on their own, as lake_walk() sees them.
  per_file <- lake_read(tbl, filter = value == max(value))
  expect_identical(nrow(per_file), nrow(lake_files(tbl)))
})

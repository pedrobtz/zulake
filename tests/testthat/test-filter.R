# Filters (design sections 5 and 6, D8): lake_files(filter =) and
# lake_partitions(filter =) on partition values and statistics, and
# lake_read(filter =) on rows. The oracles: R's evaluation of the same
# expression on deltalake's partition values, and on deltalake's full read.

test_that("partition filters keep exactly the files R's evaluation on deltalake's partition values keeps", {
  withr::local_seed(20261126)
  local_hostile_locale()
  filter_tables <- c("zl-partitioned", "delta-2.2.0-partitioned-types", "delta-0.8.0-partitioned",
                     "delta-0.8.0-null-partition", "table_with_column_mapping")
  for (table in filter_tables) {
    v <- max(oracle_versions(table))
    tbl <- lake_open(fixture_table(table))
    parts <- oracle_partition_frame(table, v)
    data_cols <- setdiff(lake_schema(tbl)$name, names(parts))
    n_checked <- 0L
    for (i in seq_len(test_iterations(150L, 40L))) {
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
  local_hostile_locale()
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
    for (i in seq_len(test_iterations(25L, 8L))) {
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
      kept <- paths[prune_files(tbl, filter_plan(expr, column_types(tbl), environment(), strict = FALSE), "double")]
      for (k in which(!paths %in% kept)) {
        pruned <- pruned + 1L
        expect_identical(nrow(r_subset(pieces[[k]], expr)), 0L, label = paste(label, paths[k]))
      }
    }
  }
  expect_gt(pruned, 50L)
})

test_that("partition values are compared as their Delta type, exactly as deltalake typed them", {
  local_hostile_locale()
  for (case in inspect_cases()) {
    tbl <- case_snapshot(case)
    pcols <- lake_partition_columns(tbl)
    if (!length(pcols)) next
    parts <- oracle_partition_frame(case$table, case$version)
    for (col in pcols) {
      values <- unique(parts[[col]])
      # By index: for () drops a Date's class before R 4.6.
      # A binary column compares on rows only: its null alone prunes.
      if (column_types(tbl)[[col]] == "binary") values <- values[is.na(values)]
      for (v in lapply(seq_along(values), function(j) values[j])) {
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

test_that("a string maximum ending in U+FFFD is only a prefix, so no value above it is pruned (#78)", {
  # The premise: Delta Spark's truncated maximum appends U+FFFD as a
  # tie-breaker, and in UTF-8 byte order U+FFFD (EF BF BD) sorts below
  # every supplementary character (F0 ...), so the maximum "abc<U+FFFD>" sorts
  # below the value "abc<U+1F600>".
  fffd <- "\uFFFD"
  emoji <- "\U0001F600"
  expect_identical(charToRaw(enc2utf8(fffd)), as.raw(c(0xEF, 0xBF, 0xBD)))
  expect_identical(charToRaw(enc2utf8(emoji))[1L], as.raw(0xF0))
  expect_identical(zulake:::bytes_cmp(paste0("abc", fffd), paste0("abc", emoji)), -1L)
  path <- file.path(withr::local_tempdir(), "t")
  dir.create(file.path(path, "_delta_log"), recursive = TRUE)
  rows <- data.frame(s = c("abc", paste0("abc", emoji), paste0("abc", fffd, fffd, emoji)))
  qio::write_parquet(rows, file.path(path, "a.parquet"))
  for (max in c("abc\\\\uFFFD", "abc\\\\uFFFD\\\\uFFFD")) {
    stats <- sprintf('{\\"numRecords\\":3,\\"minValues\\":{\\"s\\":\\"abc\\"},\\"maxValues\\":{\\"s\\":\\"%s\\"},\\"nullCount\\":{\\"s\\":0}}', max)
    writeLines(c(raw_header(c(s = "string")), raw_add("a.parquet", stats = stats)),
               file.path(path, "_delta_log", "00000000000000000000.json"), useBytes = TRUE)
    tbl <- lake_open(path)
    expect_true(endsWith(lake_files(tbl)$max[[1L]]$s, fffd))
    keeps <- function(expr) nrow(eval(bquote(lake_files(tbl, filter = .(expr))))) == 1L
    for (v in c(paste0("abc", emoji), paste0("abc", fffd, emoji), paste0("abc", fffd, fffd, emoji), "abc\U0010FFFF")) {
      for (expr in list(bquote(s == .(v)), bquote(s >= .(v)), bquote(s %in% .(v)))) {
        expect_true(keeps(expr), label = deparse(expr))
        expect_identical(eval(bquote(lake_read(tbl, filter = .(expr)))), r_subset(rows, expr), ignore_attr = TRUE, label = deparse(expr))
      }
    }
    # Below the minimum, and past every string the prefix starts, a file
    # is still pruned.
    expect_false(keeps(quote(s < "abc")))
    expect_false(keeps(quote(s == "abd")))
  }
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
  # no-null.parquet has no bounds, so it may hold a long past 2^53, which
  # reads as NA (#111): is.na() keeps it.
  expect_identical(lake_files(tbl, filter = is.na(id))$path, c("all-null.parquet", "no-null.parquet", "none.parquet"))
  expect_identical(lake_files(tbl, filter = !is.na(id))$path, c("no-null.parquet", "none.parquet"))
  expect_identical(lake_files(tbl, filter = id > 0)$path, c("no-null.parquet", "none.parquet"))
  expect_identical(lake_files(tbl, filter = id %in% c(1, NA))$path, c("all-null.parquet", "no-null.parquet", "none.parquet"))
  expect_identical(lake_files(tbl, filter = id == NA)$path, character())
  expect_identical(lake_files(tbl, filter = !(id == NA))$path, character())
  # Statistics of another column only: nothing is known of this one.
  tbl <- lake_open(raw_table(c(raw_header(c(id = "long", x = "long")),
                               raw_add("other.parquet", stats = '{\\"numRecords\\":2,\\"nullCount\\":{\\"x\\":2}}'))))
  expect_identical(lake_files(tbl, filter = is.na(id))$path, "other.parquet")
  expect_identical(lake_files(tbl, filter = !is.na(id))$path, "other.parquet")
  expect_identical(lake_files(tbl, filter = !is.na(x))$path, character())
})

test_that("a logical column alone filters rows as R does", {
  tbl <- lake_open(fixture_table("zl-types"))
  full <- suppressWarnings(lake_read(tbl))
  for (expr in list(quote(flag), quote(!flag), quote(flag | is.na(flag)), quote(xor(flag, i32 > 0)))) {
    expect_identical(suppressWarnings(eval(bquote(lake_read(tbl, filter = .(expr))))), r_subset(full, expr),
                     label = deparse(expr))
  }
  expect_error(lake_files(tbl, filter = flag), class = "zulake_error_filter")
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
  for (bad in list(1 / 3, 0.1 + 0.2, "1.2.3", " 1", "1e", "0x10", "Inf", as.raw(1), 1i)) {
    expect_error(literal_keys(bad, "exact", "long", expr), class = "zulake_error_filter", label = deparse(bad))
  }
  expect_match(conditionMessage(tryCatch(literal_keys(1 / 3, "exact", "long", expr), error = identity)),
               "write it as text", fixed = TRUE)
  # Number columns.
  num <- function(v, type = "double") literal_keys(v, "number", type, expr)$keys
  # Text against a float or double column is refused, as against a boolean
  # one: R would compare the two as strings (#73).
  for (type in c("double", "float", "boolean")) {
    for (v in list("1.5e3", "100", c("1", "2"), c(NA, "1"))) {
      expect_error(num(v, type), class = "zulake_error_filter", label = paste(type, deparse(v)))
    }
    expect_identical(num(NA_character_, type), NA_real_)
  }
  expect_identical(num(1500), 1500)
  expect_identical(num(as.Date("1970-01-11"), "date"), 10)
  expect_identical(num("1970-01-11", "date"), 10)
  expect_identical(num("1970-01-01 00:00:01.5", "timestamp"), 1.5)
  expect_identical(num("1970-01-01T01:00:00+01:00", "timestamp"), 0)
  expect_identical(num(TRUE, "boolean"), 1)
  for (bad in list(list("TRUE", "boolean"), list("tomorrow", "date"), list(Sys.time(), "date"),
                   list(Sys.Date(), "timestamp"), list("1,5", "double"), list(as.raw(1), "double"),
                   list(as.raw(1), "date"), list(1i, "timestamp"))) {
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
      lake_read(tbl, filter = value %in% c(0.5, 2, 1e6) | p_str == "café"),
      lake_read(tbl, filter = round(value / 3, 1) > 0.5 & substr(p_str, 1, 1) %in% c("a", "c") | nchar(p_str) == 4)
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
  hostile_ts <- local({
    local_hostile_locale()
    run_ts()
  })
  expect_identical(hostile_ts, plain_ts)
  plain <- run()
  hostile <- local({
    local_hostile_locale()
    run()
  })
  expect_identical(hostile, plain)
})

test_that("row-wise functions and two-column comparisons only filter rows in lake_read()", {
  tbl <- lake_open(fixture_table("zl-partitioned"))
  full <- lake_read(tbl)
  cases <- list(
    quote(nchar(p_str) > 2),
    quote(p_int + 1 == 2 | value > 1),
    quote(grepl("a", p_str) & !is.na(p_int)),
    quote(p_int %in% c(1, 2) & nchar(p_str) > 0),
    quote(TRUE),
    quote(value %% 2 == 0),
    quote(value > p_int),
    quote(xor(is.na(p_str), p_int > 2)),
    quote(substr(p_str, 1, 1) == "a"),
    quote(is.na(p_int + 1)),
    quote(round(value / 3) %in% c(0, 1))
  )
  for (expr in cases) {
    got <- eval(bquote(lake_read(tbl, filter = .(expr))))
    expect_identical(got, r_subset(full, expr), label = deparse(expr))
    expect_error(eval(bquote(lake_files(tbl, filter = .(expr)))), class = "zulake_error_filter")
    expect_error(eval(bquote(lake_partitions(tbl, filter = .(expr)))), class = "zulake_error_filter")
  }
  expect_error(lake_read(tbl, filter = p_int + 1), class = "zulake_error_filter")
  expect_error(lake_read(tbl, filter = c(TRUE, FALSE)), class = "zulake_error_filter")
  expect_error(lake_read(tbl, filter = p_int), class = "zulake_error_filter")
  expect_error(lake_read(tbl, filter = p_str), "is not logical", fixed = TRUE, class = "zulake_error_filter")
  expect_error(lake_read(tbl, filter = p_int == c(1, 2)), "must have length 1", fixed = TRUE, class = "zulake_error_filter")
  expect_error(lake_read(tbl, filter = 1 %in% p_int), "column on its left", fixed = TRUE, class = "zulake_error_filter")
  expect_error(lake_read(tbl, filter = xor(1 %in% p_int, TRUE)), "column on its left", fixed = TRUE,
               class = "zulake_error_filter")
  expect_error(lake_read(tbl, filter = abs(p_str) > 1), "evaluating it on rows failed", fixed = TRUE,
               class = "zulake_error_filter")
  # A value is a vector: a Date, a POSIXct or text for a date (?lake_read),
  # not a POSIXlt, which is a list.
  expect_error(lake_read(tbl, filter = p_date > as.POSIXlt("2024-01-01", tz = "UTC")), "a value must be a vector",
               fixed = TRUE, class = "zulake_error_filter")
  # A value inside a row-wise call must mean the same for every row.
  expect_error(lake_read(tbl, filter = value + c(1, 2) > 3), class = "zulake_error_filter")
  expect_error(lake_read(tbl, filter = grepl(p_str, "a")), class = "zulake_error_filter")
  # A row-evaluated node on partition columns never prunes, so lake_read()
  # reads every file for it.
  env <- new.env()
  tbl$storage <- remote_storage(tbl$storage, env)
  lake_read(tbl, filter = nchar(p_str) > 100)
  expect_identical(sum(startsWith(env$calls, "get ")), nrow(lake_files(tbl)))
})

test_that("a call outside the pruning subset and the row-wise list is refused everywhere (2026-11-26 correction)", {
  tbl <- lake_open(fixture_table("zl-partitioned"))
  f <- function(x) x > 1
  bad <- list(
    quote(value == max(value)), quote(value > mean(value)), quote(rank(value) <= 2),
    quote(cumsum(value) < 10), quote(!duplicated(value)), quote(value %in% p_int),
    quote(3 %in% value), quote(f(value)), quote(format(value) == "1"), quote(any(value > 3)),
    quote(value[1] == 1), quote(p_int == 1 && p_str == "a"), quote(base::nchar(p_str) > 1),
    quote(nchar(p_str) > max(p_int))
  )
  for (expr in bad) {
    for (call in list(
      bquote(lake_read(tbl, filter = .(expr))),
      bquote(lake_walk(tbl, identity, filter = .(expr))),
      bquote(lake_files(tbl, filter = .(expr))),
      bquote(lake_partitions(tbl, filter = .(expr)))
    )) {
      err <- tryCatch(eval(call), error = identity)
      expect_s3_class(err, "zulake_error_filter")
      expect_s3_class(err, "zulake_error")
    }
  }
  # On a partition column too: year == max(year) would prune with the
  # table's maximum but filter each file with its own.
  tbl <- lake_open(fixture_table("delta-0.8.0-partitioned"))
  expect_gt(nrow(lake_files(tbl)), 1L)
  for (call in list(quote(lake_read(tbl, filter = year == max(year))),
                    quote(lake_walk(tbl, identity, filter = year == max(year))),
                    quote(lake_files(tbl, filter = year == max(year))))) {
    expect_error(eval(call), class = "zulake_error_filter")
  }
  expect_match(conditionMessage(tryCatch(lake_read(tbl, filter = year == max(year)), error = identity)),
               "max() is applied to a column but is not row-wise", fixed = TRUE)
})

test_that("a filter gives the same rows however the rows are split into files", {
  withr::local_seed(20261129)
  local_hostile_locale()
  n <- 60L
  data <- data.frame(
    id = as.numeric(seq_len(n)),
    x = round(stats::rnorm(n, sd = 10), 1),
    k = sample(c(1:5, NA), n, replace = TRUE),
    s = sample(c("a", "ab", "b", "B", "caf\u00e9", NA), n, replace = TRUE),
    d = as.Date("2024-01-01") + sample(c(0:9, NA), n, replace = TRUE),
    flag = sample(c(TRUE, FALSE, NA), n, replace = TRUE),
    stringsAsFactors = FALSE
  )
  one <- lake_open(split_table(data, 1L))
  here <- environment()
  many <- lapply(c(2L, 7L, 20L), function(k) lake_open(split_table(data, k, env = here)))
  expect_identical(lake_read(one), data, ignore_attr = TRUE)
  # What a filter that looks at other rows would give differs by layout; so
  # each is refused, the same way, whatever the layout.
  outcome <- function(tbl, expr) {
    tryCatch(eval(bquote(lake_read(tbl, filter = .(expr)))), zulake_error_filter = function(e) "refused")
  }
  for (expr in list(quote(x == max(x)), quote(x > mean(x, na.rm = TRUE)), quote(rank(id) <= 2),
                    quote(cumsum(id) < 100), quote(!duplicated(s)), quote(any(x > 3)))) {
    want <- outcome(one, expr)
    expect_identical(want, "refused", label = deparse(expr))
    for (tbl in many) expect_identical(outcome(tbl, expr), want, label = deparse(expr))
  }
  for (i in seq_len(test_iterations(80L, 10L))) {
    expr <- random_row_filter(data)
    label <- paste(deparse(expr), collapse = " ")
    want <- suppressWarnings(eval(bquote(lake_read(one, filter = .(expr)))))
    expect_identical(want, r_subset(data, expr), ignore_attr = TRUE, label = label)
    for (tbl in many) {
      got <- suppressWarnings(eval(bquote(lake_read(tbl, filter = .(expr)))))
      expect_identical(got, want, label = label)
      pieces <- list()
      suppressWarnings(eval(bquote(lake_walk(tbl, function(p) pieces[[length(pieces) + 1L]] <<- p, filter = .(expr)))))
      bound <- if (length(pieces)) do.call(rbind, pieces) else want[0L, , drop = FALSE]
      expect_identical(bound, want, ignore_attr = TRUE, label = label)
    }
  }
})

test_that("the row-wise functions are base R's, whatever the caller defines", {
  tbl <- lake_open(fixture_table("zl-partitioned"))
  full <- lake_read(tbl)
  want <- r_subset(full, quote(nchar(p_str) > 2 & abs(value) >= 0))
  nchar <- function(x) max(x)
  abs <- function(x) -1
  `>` <- function(e1, e2) TRUE
  expect_identical(lake_read(tbl, filter = nchar(p_str) > 2 & abs(value) >= 0), want)
  # A value is evaluated in the caller's environment, with the caller's
  # functions: here nchar("a") is the local max("a"), "a".
  rm(`>`)
  got <- lake_read(tbl, filter = p_str == nchar("a"))
  expect_gt(nrow(got), 0L)
  expect_identical(got, full[full$p_str %in% "a", , drop = FALSE], ignore_attr = TRUE)
})

test_that("a binary column is filtered on rows; is.na() of it is TRUE for a null, unlike base R on a list", {
  tbl <- lake_open(fixture_table("zl-types"))
  full <- suppressWarnings(lake_read(tbl))
  null <- vapply(full$b, is.null, NA)
  expect_identical(sum(null), 1L)
  read <- function(expr) suppressWarnings(eval(bquote(lake_read(tbl, filter = .(expr)))))
  # A comparison has no statistics to use, and equals R's.
  for (expr in list(quote(b == "x"), quote(b != "x"), quote(is.na(i32) | b == "x"))) {
    expect_identical(read(expr), r_subset(full, expr), label = deparse(expr))
  }
  # is.na() is the Delta null (design section 6), as vapply(b, is.null, NA)
  # finds it; base R's is.na() is FALSE for every element of a list.
  expect_identical(read(quote(is.na(b))), r_subset(full, bquote(.(null))))
  expect_identical(read(quote(!is.na(b))), r_subset(full, bquote(.(!null))))
  expect_identical(nrow(r_subset(full, quote(is.na(b)))), 0L)
  expect_identical(nrow(suppressWarnings(lake_files(tbl, filter = is.na(b)))), 1L)
})

test_that("a text literal against a float or double column is refused everywhere (#73)", {
  tbl <- lake_open(system.file("extdata", "orders", package = "zulake"))
  rows <- lake_read(tbl)
  # R compares a double with text as strings, which is not what pruning on
  # the number would keep: the two disagree on the shipped table.
  expect_false(identical(nrow(subset(rows, amount > "100")), nrow(subset(rows, amount > 100))))
  for (expr in list(quote(amount > "100"), quote(amount == "12.5"), quote(amount %in% c("1", "2")),
                    quote(region == "EU" & amount >= "100"), quote(!(amount < "100")))) {
    expect_error(eval(bquote(lake_read(tbl, filter = .(expr)))), class = "zulake_error_filter", label = deparse(expr))
    expect_error(eval(bquote(lake_walk(tbl, identity, filter = .(expr)))), class = "zulake_error_filter", label = deparse(expr))
    expect_error(eval(bquote(lake_files(tbl, filter = .(expr)))), class = "zulake_error_filter", label = deparse(expr))
  }
  expect_identical(lake_read(tbl, filter = amount > 100), rows[rows$amount > 100, , drop = FALSE], ignore_attr = TRUE)
})

test_that("text functions of a timestamp column are refused on R before 4.3 (#74)", {
  # Before R 4.3.0, as.character() of a POSIXct (and substr(), toupper(),
  # tolower() and grepl(), which call it) chose one format for the whole
  # vector, so its value for a row depended on the other rows of the file.
  tbl <- lake_open(fixture_table("zl-types"))
  rows <- suppressWarnings(lake_read(tbl, columns = c("i16", "d", "ts", "ntz")))
  refused <- list(
    quote(as.character(ts) == "2024-01-01"), quote(substr(ntz, 1, 4) == "2024"),
    quote(toupper(ts) == "X"), quote(tolower(ntz) == "x"), quote(grepl("2024", ts)),
    quote(as.character(ts + 1) == "x"), quote(i16 > 0 | nchar(as.character(ntz)) > 0)
  )
  allowed <- list(
    quote(as.character(d) == "2024-01-01"), quote(as.numeric(ts) > 0), quote(nchar(as.character(i16)) > 1),
    quote(ts > as.POSIXct("2000-01-01", tz = "UTC"))
  )
  read <- function(expr) eval(bquote(lake_read(tbl, columns = c("i16", "d", "ts", "ntz"), filter = .(expr))))
  for (old in c("4.2.3", "3.5.0")) {
    local({
      local_mocked_bindings(r_version = function() package_version(old))
      for (expr in refused) {
        err <- tryCatch(read(expr), error = identity)
        expect_s3_class(err, "zulake_error_filter")
        expect_match(conditionMessage(err), "R 4.3.0", fixed = TRUE)
      }
      for (expr in allowed) expect_identical(read(expr), r_subset(rows, expr), ignore_attr = TRUE, label = deparse(expr))
    })
  }
  # From R 4.3.0 on they are row-wise, and read as subset() does.
  local_mocked_bindings(r_version = function() package_version("4.3.0"))
  for (expr in c(refused, allowed)) {
    expect_identical(read(expr), r_subset(rows, expr), ignore_attr = TRUE, label = deparse(expr))
  }
})

test_that("equivalent filters agree on an int32 of -2^31, which qio reads as NA (#79)", {
  # zl-int32-min: one file, i32 = -2^31, 1, 5 and nullCount 0. qio reads
  # -2^31 as NA (R's integer NA), so is.na() is TRUE on that row, and the
  # null count of 0 must not prune it.
  tbl <- lake_open(fixture_table("zl-int32-min"))
  rows <- suppressWarnings(lake_read(tbl))
  expect_identical(rows$i32, c(NA, 1L, 5L))
  expect_identical(lake_files(tbl)$null_count[[1L]]$i32, 0)
  for (expr in list(quote(i32 < 1), quote(i32 == -2147483648), quote(is.na(i32)), quote(i32 %in% NA),
                    quote(i32 %in% c(1, 5, NA)), quote(is.na(i32 + 0L)), quote(!is.na(i32)), quote(!(i32 %in% NA)))) {
    got <- suppressWarnings(eval(bquote(lake_read(tbl, filter = .(expr)))))
    expect_identical(got, r_subset(rows, expr), ignore_attr = TRUE, label = deparse(expr))
  }
  expect_identical(nrow(lake_files(tbl, filter = is.na(i32))), 1L)
  expect_identical(nrow(lake_files(tbl, filter = i32 %in% NA)), 1L)
  # A file whose minimum is known and above -2^31 is still pruned on its
  # null count; a missing minimum, or one of -2^31, is not.
  stats <- function(min) sprintf('{\\"numRecords\\":2,\\"minValues\\":{%s},\\"maxValues\\":{\\"i32\\":5},\\"nullCount\\":{\\"i32\\":0}}', min)
  kept <- function(min, type = "integer") {
    t <- lake_open(raw_table(c(raw_header(c(i32 = type)), raw_add("a.parquet", stats = stats(min)))))
    nrow(lake_files(t, filter = is.na(i32))) == 1L
  }
  expect_false(kept('\\"i32\\":-2147483647'))
  expect_false(kept('\\"i32\\":0'))
  expect_true(kept('\\"i32\\":-2147483648'))
  expect_true(kept(""))
  # Other integer types hold their minimum in R: their null count prunes.
  for (type in c("byte", "short", "long")) expect_false(kept('\\"i32\\":-128', type), label = type)
})

test_that("a quoted filter in a variable is refused with how to pass it (#92)", {
  tbl <- lake_open(system.file("extdata", "orders", package = "zulake"))
  q <- quote(amount > 100)
  for (call in list(quote(lake_read(tbl, filter = q)), quote(lake_files(tbl, filter = q)))) {
    err <- tryCatch(eval(call), error = identity)
    expect_s3_class(err, "zulake_error_filter")
    expect_match(conditionMessage(err), "eval(bquote(", fixed = TRUE)
  }
  expect_identical(eval(bquote(lake_read(tbl, filter = .(q)))), lake_read(tbl, filter = amount > 100))
})

test_that("is.na() on a long column is not pruned where the read gives NA for a value (#111)", {
  skip_if_not_installed("bit64")
  # zl-int64-edges: six files, nullCount 0 in each, i64 holding
  # ±(2^53 - 1), ±2^53, -2^63, 2^63 - 1 and 2^53 + 1. qio reads a value past
  # 2^53 as NA with int64 = "double", and -2^63 as bit64's NA with
  # "integer64", where the null count does not count them.
  tbl <- lake_open(fixture_table("zl-int64-edges"))
  exprs <- list(quote(is.na(i64)), quote(!is.na(i64)), quote(i64 %in% NA), quote(i64 %in% c(5, NA)),
                quote(!(i64 %in% NA)), quote(i64 == 5 | is.na(i64)), quote(is.na(i64) & id > 0),
                quote(is.na(i64 + 0)), quote(i64 > 0), quote(i64 < -2^52))
  na_ids <- list(double = c(7, 9, 11), integer64 = 7)
  for (int64 in c("double", "integer64")) {
    rows <- suppressWarnings(lake_read(tbl, int64 = int64))
    expect_setequal(rows$id[is.na(rows$i64)], na_ids[[int64]])
    for (expr in exprs) {
      got <- suppressWarnings(eval(bquote(lake_read(tbl, filter = .(expr), int64 = int64))))
      expect_identical(got, r_subset(rows, expr), ignore_attr = TRUE, label = paste(int64, deparse(expr)))
    }
  }
  # Only the files whose bounds are known and inside what the mode holds
  # are pruned on the null count: one file with "double" (±(2^53 - 1)),
  # five with "integer64" (all but the one whose minimum is -2^63).
  expect_identical(nrow(lake_files(tbl, filter = is.na(i64), stats = FALSE)), 5L)
  expect_identical(nrow(lake_files(tbl, filter = is.na(i64), int64 = "integer64", stats = FALSE)), 1L)
  expect_identical(nrow(lake_files(tbl, filter = i64 %in% NA, int64 = "integer64", stats = FALSE)), 1L)
  # A missing bound is unknown, so the file is kept; bounds inside the mode
  # prune.
  stats <- function(min, max) {
    sprintf('{\\"numRecords\\":2,\\"minValues\\":{%s},\\"maxValues\\":{%s},\\"nullCount\\":{\\"i64\\":0}}', min, max)
  }
  kept <- function(min, max, int64) {
    t <- lake_open(raw_table(c(raw_header(c(i64 = "long")), raw_add("a.parquet", stats = stats(min, max)))))
    nrow(suppressWarnings(lake_files(t, filter = is.na(i64), int64 = int64))) == 1L
  }
  bound <- function(v) sprintf('\\"i64\\":%s', v)
  expect_false(kept(bound("-9007199254740991"), bound("9007199254740991"), "double"))
  expect_true(kept(bound("-9007199254740992"), bound("1"), "double"))
  expect_true(kept(bound("1"), bound("9007199254740992"), "double"))
  expect_true(kept("", bound("1"), "double"))
  expect_true(kept(bound("1"), "", "double"))
  expect_false(kept(bound("-9223372036854775807"), bound("9223372036854775807"), "integer64"))
  expect_false(kept(bound("1"), "", "integer64"))
  expect_true(kept(bound("-9223372036854775808"), bound("1"), "integer64"))
  expect_true(kept("", bound("1"), "integer64"))
})

test_that("is.na() of a binary column means the Delta null in every form (#113)", {
  tbl <- lake_open(fixture_table("zl-types"))
  rows <- suppressWarnings(lake_read(tbl, columns = c("i8", "b", "s")))
  # The oracle: R's subset() of the unfiltered read, with is.na(b) and
  # b %in% NA read as vapply(b, is.null, NA) (design section 6).
  rows$null_b <- vapply(rows$b, is.null, NA)
  expect_identical(sum(rows$null_b), 1L)
  as_null <- function(e) {
    if (identical(e, quote(is.na(b)))) {
      return(quote(null_b))
    }
    if (is.call(e) && identical(e[[1L]], as.name("%in%")) && identical(e[[2L]], quote(b))) {
      # A null is in the values when one of them is NA.
      return(bquote((null_b & .(anyNA(eval(e[[3L]])))) | (!null_b & .(e))))
    }
    if (is.call(e)) {
      for (i in seq_along(e)[-1L]) e[[i]] <- as_null(e[[i]])
    }
    e
  }
  forms <- list(quote(is.na(b)), quote(!(!is.na(b))), quote(is.na(b) == TRUE), quote(is.na(b) & TRUE),
                quote(xor(is.na(b), FALSE)), quote(is.na(b) | FALSE), quote(!is.na(b)), quote(is.na(b) == FALSE),
                quote(is.na(b) != TRUE), quote(is.na(b) == is.na(s)), quote(b %in% NA), quote(!(b %in% NA)),
                quote(b %in% c("x", NA)), quote(b %in% "x"), quote(is.na(b) | i8 > 100), quote(as.integer(is.na(b)) == 1L))
  for (expr in forms) {
    got <- suppressWarnings(eval(bquote(lake_read(tbl, columns = c("i8", "b", "s"), filter = .(expr)))))
    want <- r_subset(rows, as_null(expr))
    expect_identical(got$i8, want$i8, label = deparse(expr))
  }
  # The string column's null row, for comparison: %in% NA is the null there
  # too.
  expect_identical(suppressWarnings(lake_read(tbl, columns = "i8", filter = s %in% NA))$i8,
                   suppressWarnings(lake_read(tbl, columns = "i8", filter = b %in% NA))$i8)
})

test_that("exact filters give R's rows whatever LC_NUMERIC's decimal point is (#114)", {
  locale <- local_hostile_locale()
  skip_if(is.na(locale$numeric), "no locale with a comma decimal point is installed")
  expect_identical(sprintf("%.1f", 1.5), "1,5")
  tbl <- lake_open(fixture_table("zl-types"))
  rows <- suppressWarnings(lake_read(tbl))
  rows <- rows[!vapply(rows, is.list, NA)]
  exprs <- list(quote(dec == 12345678.9), quote(dec > 0), quote(dec %in% c(-0.01, 0)), quote(dec < -0.005),
                quote(i32 > 0.5), quote(i16 == 32767), quote(i64 > 1.5), quote(i8 %in% c(1, -1.5)),
                quote(f64 == 0.1), quote(f32 > 1.25), quote(dec >= "0.00"))
  for (expr in exprs) {
    got <- suppressWarnings(eval(bquote(lake_read(tbl, columns = names(rows), filter = .(expr)))))
    expect_identical(got, r_subset(rows, expr), ignore_attr = TRUE, label = deparse(expr))
  }
  tbl <- lake_open(fixture_table("zl-decimal-partitions"))
  rows <- lake_read(tbl)
  for (expr in list(quote(pdec == 12.3), quote(pdec > 0.05), quote(pd4 == 12.34), quote(pd4 < -1.5),
                    quote(pdec %in% c(-0.01, 12.3)))) {
    got <- eval(bquote(lake_read(tbl, filter = .(expr))))
    expect_identical(got, r_subset(rows, expr), ignore_attr = TRUE, label = deparse(expr))
  }
})

test_that("a statistic whose JSON type is not the column's is unknown, and the file is kept (#115)", {
  # For each Delta type: the JSON type its statistics have, a value of it,
  # and a filter that value as both bounds prunes. Every other JSON type in
  # those bounds must keep the file.
  cases <- list(
    byte = list(json = "number", filter = quote(x > 5)),
    short = list(json = "number", filter = quote(x > 5)),
    integer = list(json = "number", filter = quote(x > 5)),
    long = list(json = "number", filter = quote(x > 5)),
    "decimal(10,2)" = list(json = "number", filter = quote(x > 5)),
    float = list(json = "number", filter = quote(x > 5)),
    double = list(json = "number", filter = quote(x > 5)),
    boolean = list(json = "boolean", filter = quote(x == FALSE)),
    string = list(json = "string", filter = quote(x > "5")),
    date = list(json = "string", filter = quote(x > as.Date("2024-01-05"))),
    timestamp = list(json = "string", filter = quote(x > as.POSIXct("2024-01-05", tz = "UTC"))),
    timestamp_ntz = list(json = "string", filter = quote(x > as.POSIXct("2024-01-05", tz = "UTC")))
  )
  right <- c(byte = "1", short = "1", integer = "1", long = "1", "decimal(10,2)" = "1.00", float = "1.0",
             double = "1.0", boolean = "true", string = '\\"1\\"', date = '\\"2024-01-01\\"',
             timestamp = '\\"2024-01-01T00:00:00.000Z\\"', timestamp_ntz = '\\"2024-01-01 00:00:00.000\\"')
  json_values <- list(number = c("1", "0"), boolean = c("true", "false"), string = c('\\"1\\"', '\\"0\\"', '\\"2024-01-01\\"'),
                      array = "[1]", object = '{\\"a\\":1}')
  kept <- function(type, value, filter) {
    stats <- sprintf(
      '{\\"numRecords\\":2,\\"minValues\\":{\\"x\\":%s},\\"maxValues\\":{\\"x\\":%s},\\"nullCount\\":{\\"x\\":0}}',
      value, value
    )
    t <- lake_open(raw_table(c(raw_header(c(x = type)), raw_add("a.parquet", stats = stats))))
    nrow(eval(bquote(lake_files(t, filter = .(filter), stats = FALSE)))) == 1L
  }
  for (type in names(cases)) {
    case <- cases[[type]]
    # The test sees a bound: the right JSON type prunes.
    expect_false(kept(type, right[[type]], case$filter), label = paste(type, right[[type]]))
    for (json in setdiff(names(json_values), case$json)) {
      for (value in json_values[[json]]) {
        expect_true(kept(type, value, case$filter), label = paste(type, value))
      }
    }
  }
  # On a fixture: zl-basic's first file (id 1 to 3) with maxValues.id true
  # reads as subset() of the unfiltered read.
  path <- local_fixture_copy("zl-basic")
  f <- file.path(path, "_delta_log", "00000000000000000000.json")
  lines <- readLines(f, warn = FALSE)
  stopifnot(sum(grepl('\\"maxValues\\":{\\"label\\":\\"c\\",\\"id\\":3,', lines, fixed = TRUE)) == 1L)
  lines <- sub('\\"maxValues\\":{\\"label\\":\\"c\\",\\"id\\":3,', '\\"maxValues\\":{\\"label\\":\\"c\\",\\"id\\":true,',
               lines, fixed = TRUE)
  writeLines(lines, f)
  tbl <- lake_open(path, version = 0)
  rows <- lake_read(tbl)
  for (expr in list(quote(id > 2), quote(id == 3), quote(!(id %in% 1)), quote(id >= 2 & label == "c"))) {
    expect_identical(eval(bquote(lake_read(tbl, filter = .(expr)))), r_subset(rows, expr), ignore_attr = TRUE,
                     label = deparse(expr))
  }
})

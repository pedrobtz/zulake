# lake_files(filter =) and lake_partitions(filter =) on partition columns
# (design sections 5 and 6, D8). The oracle evaluates the same expression in
# R on deltalake's typed partition values of each file.

test_that("partition filters keep exactly the files R's evaluation on deltalake's partition values keeps", {
  withr::local_seed(20261126)
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
      expect_identical(got, expected, label = paste(table, deparse(expr)))
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
  # A comparison with a data column cannot rule a file out yet.
  expect_identical(lake_files(tbl, filter = value > 1e9, stats = FALSE)$path, all$path)
  expect_identical(lake_files(tbl, filter = value > 1e9 & p_int == 4L, stats = FALSE)$path, all$path[1])
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
    quote(p_int == c(1, 2)),
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
  expect_identical(lake_files(tbl, filter = id > 100)$path, lake_files(tbl)$path)
  expect_identical(dim(lake_partitions(tbl)), c(0L, 0L))
  path <- hand_table(c(protocol_line(), metadata_line(c(id = "long", p = "integer"), partition = "p")))
  tbl <- lake_open(path)
  expect_identical(nrow(lake_files(tbl, filter = p == 1)), 0L)
  expect_identical(names(lake_partitions(tbl, filter = p == 1)), "p")
})

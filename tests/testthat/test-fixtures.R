# The corpus and the oracle that later stages compare against: the fixture
# tables, deltalake 1.7.0's answers for them, and expect_oracle().

test_that("every fixture table has an answer file for each of its versions", {
  tables <- fixture_names("tables")
  expect_gt(length(tables), 20L)
  expect_setequal(list.files(oracle_answers_dir()), tables)
  for (table in tables) {
    logged <- fixture_log_versions(fixture_table(table))
    expect_gt(length(logged), 0L)
    expect_identical(oracle_versions(table), as.numeric(seq(0, max(logged))), label = table)
    for (version in oracle_versions(table)) {
      answer <- oracle_answer(table, version)
      expect_identical(answer$deltalake, "1.7.0")
      expect_identical(answer$table, table)
      expect_identical(as.numeric(answer$version), version)
    }
  }
})

test_that("answers name what deltalake refused and why", {
  refusal <- oracle_refusal("zl-unknown-reader-feature", 1)
  expect_identical(refusal$class, "DeltaError")
  expect_match(refusal$message, "zulakeUnknownFeature", fixed = TRUE)
  expect_null(oracle_refusal("zl-unknown-reader-feature", 0))
  expect_null(oracle_refusal("zl-basic", 4))
})

test_that("answers hold no absolute path", {
  for (table in fixture_names("tables")) {
    for (version in oracle_versions(table)) {
      path <- file.path(oracle_answers_dir(), table, paste0(version, ".json"))
      text <- readLines(path, warn = FALSE, encoding = "UTF-8")
      # The harness ran on a scratch copy; its location must not leak. (Some
      # delta-rs commits quote the /tmp path Spark wrote them at: data.)
      expect_false(any(grepl("file://|/var/folders/|/private/|/Users/|/home/|[A-Z]:\\\\", text)), label = path)
    }
  }
})

test_that("expect_oracle() passes on deltalake's own answer, rows in any order", {
  read <- oracle_field("zl-types", 0, "read")
  actual <- oracle_table_frame(read)
  expect_success(expect_oracle(actual, "zl-types", 0, "read"))
  expect_success(expect_oracle(actual[rev(seq_len(nrow(actual))), ], "zl-types", 0, "read"))
  expect_success(expect_oracle(actual[c("i64", "s")], "zl-types", 0, "read"))
  expect_success(expect_oracle(8, "table-with-dv-small", 1, "count"))
  expect_success(expect_oracle(8L, "table-with-dv-small", 1, "count"))
})

test_that("expect_oracle() fails on one changed value in a known answer", {
  read <- oracle_field("zl-types", 0, "read")
  base <- oracle_table_frame(read)

  changed <- base
  i <- match("9007199254740993", changed$i64)
  changed$i64[i] <- "9007199254740992"
  expect_failure(expect_oracle(changed, "zl-types", 0, "read"))

  # The same value as a double rounds to 2^53 and must not pass.
  as_double <- base[c("i8", "i64")]
  as_double$i64 <- as.numeric(as_double$i64)
  expect_failure(expect_oracle(as_double, "zl-types", 0, "read"))

  changed <- base
  changed$s[match("café", changed$s)] <- "cafe"
  expect_failure(expect_oracle(changed, "zl-types", 0, "read"))

  # A signed zero is a different double.
  changed <- base["f64"]
  j <- which(vapply(changed$f64, identical, NA, -0, num.eq = FALSE))
  expect_length(j, 1L)
  changed$f64[[j]] <- 0
  expect_failure(expect_oracle(changed, "zl-types", 0, "read"))

  changed <- base
  changed$st[[2L]]$a <- "2"
  expect_failure(expect_oracle(changed, "zl-types", 0, "read"))

  expect_failure(expect_oracle(base[-1L, ], "zl-types", 0, "read"))
  expect_failure(expect_oracle(cbind(base, extra = 1), "zl-types", 0, "read"))
  expect_failure(expect_oracle(9, "table-with-dv-small", 1, "count"))
})

test_that("expect_oracle() compares nested answers field by field", {
  dv <- oracle_field("table-with-dv-small", 1, "deletion_vectors")
  expect_identical(dv[[1L]]$deleted_rows, c(0L, 9L))
  expect_success(expect_oracle(
    list(list(path = dv[[1L]]$path, deleted_rows = c(0, 9), selection_vector_length = 10)),
    "table-with-dv-small", 1, "deletion_vectors"
  ))
  expect_failure(expect_oracle(
    list(list(path = dv[[1L]]$path, deleted_rows = c(0, 8), selection_vector_length = 10)),
    "table-with-dv-small", 1, "deletion_vectors"
  ))
  expect_success(expect_oracle(list(min_reader_version = 3, min_writer_version = 7,
                                    reader_features = "deletionVectors",
                                    writer_features = "deletionVectors"),
                               "table-with-dv-small", 1, "protocol"))
  expect_failure(expect_oracle(list(min_reader_version = 3, min_writer_version = 7,
                                    reader_features = "deletionVector",
                                    writer_features = "deletionVectors"),
                               "table-with-dv-small", 1, "protocol"))
})

test_that("an independent Parquet reader agrees with the oracle's encoding", {
  # qio reads the one data file of zl-basic at version 0, and the columns of
  # zl-types it reads exactly; deltalake's answers encode the same values.
  basic <- fixture_table("zl-basic")
  add <- oracle_field("zl-basic", 0, c("add_actions", "columns", "path"))
  expect_length(add, 1L)
  df <- qio::read_parquet(file.path(basic, add))
  expect_success(expect_oracle(df, "zl-basic", 0, "read"))

  types <- fixture_table("zl-types")
  add <- oracle_field("zl-types", 0, c("add_actions", "columns", "path"))
  df <- suppressMessages(qio::read_parquet(
    file.path(types, add),
    columns = c("i8", "i16", "f32", "f64", "s", "b", "flag", "d", "ts", "ntz")
  ))
  expect_success(expect_oracle(df, "zl-types", 0, "read"))
})

test_that("each hostile log differs from the table it was made from", {
  sources <- c(
    "add-then-remove-same-file" = "zl-basic",
    "checkpoint-map-repeated-key" = "zl-checkpoint-no-last",
    "column-mapping-duplicate-physical-name" = "column_mapping",
    "column-mapping-no-physical-name" = "column_mapping",
    "corrupt-commit" = "zl-basic",
    "data-type-long-for-integer" = "zl-basic",
    "data-type-string-for-long" = "zl-basic",
    "decimal-partition-exponent" = "zl-decimal-partitions",
    "decimal-partition-negative-no-integer-digit" = "zl-decimal-partitions",
    "decimal-partition-no-fraction-digit" = "zl-decimal-partitions",
    "decimal-partition-no-integer-digit" = "zl-decimal-partitions",
    "decimal-partition-past-precision" = "zl-decimal-partitions",
    "decimal-partition-past-precision-small" = "zl-decimal-partitions",
    "decimal-partition-past-scale" = "zl-decimal-partitions",
    "duplicate-action-key" = "zl-basic",
    "duplicate-key-in-add" = "zl-basic",
    "dv-bad-checksum" = "table-with-dv-small",
    "dv-bad-magic" = "table-with-dv-small",
    "dv-size-past-file" = "table-with-dv-small",
    "last-checkpoint-past-log" = "zl-checkpoint",
    "missing-checkpoint-part" = "zl-multipart-checkpoint",
    "partition-value-wrong-type" = "zl-partitioned",
    "remove-then-add-same-file" = "zl-basic",
    "schema-duplicate-name" = "zl-basic",
    "schema-duplicate-name-case" = "zl-basic",
    "schema-duplicate-name-case-nested" = "zl-basic",
    "schema-empty-name" = "zl-basic",
    "schema-field-without-name" = "zl-basic",
    "schema-field-without-type" = "zl-basic",
    "schema-repeated-key" = "zl-basic",
    "schema-timestamp-ntz-without-feature" = "zl-basic",
    "schema-unknown-type" = "zl-basic",
    "schema-upper-case-type" = "zl-basic",
    "schema-variant-without-feature" = "zl-basic",
    "stats-repeated-column" = "zl-basic",
    "stats-repeated-key" = "zl-basic",
    "truncated-commit" = "zl-basic",
    "two-actions-one-line" = "zl-basic",
    "two-adds-same-file" = "zl-basic",
    "two-adds-same-path-new-dv" = "table-with-dv-small",
    "two-removes-same-file" = "zl-basic"
  )
  expect_identical(fixture_names("hostile"), names(sources))
  for (name in names(sources)) {
    bad <- fixture_table(name, "hostile")
    good <- fixture_table(sources[[name]])
    files <- union(
      list.files(bad, recursive = TRUE, all.files = TRUE),
      list.files(good, recursive = TRUE, all.files = TRUE)
    )
    md5 <- function(dir) unname(tools::md5sum(file.path(dir, files)))
    changed <- files[!(md5(bad) %in% md5(good)) | is.na(md5(bad)) | is.na(md5(good))]
    expect_length(changed, 1L)
  }
})

test_that("the shipped tar holds exactly the unpacked fixture trees", {
  # The unpacked trees are in the source tree only (.Rbuildignore), so this
  # runs under devtools::test() and in oracle.yaml, which also fails if it
  # skips (#64); every R CMD check leg skips it.
  src <- testthat::test_path("fixtures")
  skip_if_not(dir.exists(file.path(src, "tables")), "unpacked fixture trees not in this tree")
  for (kind in c("tables", "hostile")) {
    files <- sort(list.files(file.path(src, kind), recursive = TRUE, all.files = TRUE))
    packed <- sort(list.files(file.path(fixture_dir(), kind), recursive = TRUE, all.files = TRUE))
    expect_identical(packed, files)
    expect_identical(
      unname(tools::md5sum(file.path(fixture_dir(), kind, files))),
      unname(tools::md5sum(file.path(src, kind, files)))
    )
  }
})

test_that("local_fixture_copy() gives a private copy that goes away", {
  outer <- NULL
  local({
    path <- local_fixture_copy("zl-basic")
    outer <<- path
    expect_true(dir.exists(file.path(path, "_delta_log")))
    unlink(file.path(path, "_delta_log", "00000000000000000004.json"))
    expect_true(file.exists(file.path(fixture_table("zl-basic"), "_delta_log", "00000000000000000004.json")))
  })
  expect_false(dir.exists(outer))
})

test_that("oracle_canon() writes each value exactly", {
  expect_identical(oracle_canon(2^53), "9007199254740992")
  expect_identical(oracle_canon(2^60), "1152921504606846976")
  expect_identical(oracle_canon(0.1), "0.10000000000000001")
  expect_identical(oracle_canon(-0), "-0")
  expect_identical(oracle_canon(c(NaN, Inf, -Inf, NA)), list("NaN", "Infinity", "-Infinity", "null"))
  expect_identical(oracle_canon(5L), oracle_canon(5))
  expect_identical(oracle_canon(TRUE), "true")
  expect_identical(oracle_canon(as.raw(c(0xde, 0xad))), "dead")
  expect_identical(oracle_canon(as.Date("0001-01-01")), "0001-01-01")
  expect_identical(oracle_canon(as.Date(2932896, origin = "1970-01-01")), "9999-12-31")
  ts <- as.POSIXct(-1e-6, origin = "1970-01-01", tz = "UTC")
  expect_identical(oracle_canon(ts), "1969-12-31T23:59:59.999999")
  ts <- as.POSIXct(1709209845.123456, origin = "1970-01-01", tz = "UTC")
  expect_identical(oracle_canon(ts), oracle_canon("2024-02-29T12:30:45.123456Z"))
  expect_identical(oracle_canon(list(b = 1, a = "x")), list(a = "x", b = "1"))
  expect_identical(oracle_canon(NULL), "null")
})

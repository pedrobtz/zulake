# Hostile logs (design section 8): each is a classed zulake_error, and no
# snapshot is returned. The checkpoint and deletion-vector ones are Stage 2b
# and Stage 5's.

test_that("a truncated commit is a corrupt log, and no snapshot is returned", {
  path <- fixture_table("truncated-commit", "hostile")
  expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
  err <- tryCatch(lake_open(path), error = identity)
  expect_s3_class(err, "zulake_error")
  expect_identical(err$file, "00000000000000000004.json")
  expect_s3_class(err$parent, "zujson_parse_error")
  # The versions before it are whole, and equal zl-basic's.
  tbl <- lake_open(path, version = 3)
  expect_oracle(replay_files_frame(tbl, "path"), "zl-basic", 3, "add_actions")
})

test_that("a commit with a line that is not JSON is a corrupt log, and no snapshot is returned", {
  path <- fixture_table("corrupt-commit", "hostile")
  expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
  expect_no_snapshot(lake_open(path, version = 2), "zulake_error_corrupt_log")
  expect_identical(tryCatch(lake_open(path), error = identity)$file, "00000000000000000002.json")
  tbl <- lake_open(path, version = 1)
  expect_oracle(replay_files_frame(tbl, "path"), "zl-basic", 1, "add_actions")
})

test_that("a partition value of the wrong type is a corrupt log, and no snapshot is returned", {
  path <- fixture_table("partition-value-wrong-type", "hostile")
  expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
  expect_no_snapshot(lake_open(path, version = 1), "zulake_error_corrupt_log")
  err <- tryCatch(lake_open(path), error = identity)
  expect_identical(err$column, "p_int")
  tbl <- lake_open(path, version = 0)
  expect_oracle(replay_files_frame(tbl, "path"), "zl-partitioned", 0, "add_actions")
})

test_that("a _last_checkpoint past the end of the log is a corrupt log", {
  path <- fixture_table("last-checkpoint-past-log", "hostile")
  expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
  expect_no_snapshot(lake_open(path, version = 3), "zulake_error_corrupt_log")
})

test_that("a _last_checkpoint that is not JSON, or has no version, is a corrupt log", {
  path <- hand_table()
  f <- file.path(path, "_delta_log", "_last_checkpoint")
  for (text in c("{\"version\":", "[1]", "{\"size\":3}", "{\"version\":-1}", "{\"version\":1.5}", "{\"version\":\"0\"}")) {
    writeLines(text, f)
    expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
  }
  writeLines("{\"version\":0,\"size\":3}", f)
  expect_identical(lake_open(path)$last_checkpoint[["version"]], 0)
})

test_that("each malformed action is a corrupt log, and no snapshot is returned", {
  good_p <- protocol_line()
  good_m <- metadata_line()
  bad <- list(
    not_an_object = c(good_p, good_m, "[1, 2]"),
    a_string = c(good_p, good_m, "\"add\""),
    empty_object = c(good_p, good_m, "{}"),
    add_without_path = c(good_p, good_m, "{\"add\":{\"size\":1,\"partitionValues\":{}}}"),
    add_empty_path = c(good_p, good_m, "{\"add\":{\"path\":\"\",\"size\":1,\"partitionValues\":{}}}"),
    add_without_size = c(good_p, good_m, "{\"add\":{\"path\":\"a\",\"partitionValues\":{}}}"),
    add_negative_size = c(good_p, good_m, "{\"add\":{\"path\":\"a\",\"size\":-1,\"partitionValues\":{}}}"),
    add_text_size = c(good_p, good_m, "{\"add\":{\"path\":\"a\",\"size\":\"1\",\"partitionValues\":{}}}"),
    add_values_not_strings = c(good_p, good_m, "{\"add\":{\"path\":\"a\",\"size\":1,\"partitionValues\":{\"k\":1}}}"),
    add_bad_dv = c(good_p, good_m, "{\"add\":{\"path\":\"a\",\"size\":1,\"partitionValues\":{},\"deletionVector\":{\"storageType\":\"x\",\"pathOrInlineDv\":\"y\"}}}"),
    add_path_number = c(good_p, good_m, "{\"add\":{\"path\":1,\"size\":1,\"partitionValues\":{}}}"),
    remove_without_path = c(good_p, good_m, "{\"remove\":{\"deletionTimestamp\":1}}"),
    remove_bad_dv = c(good_p, good_m, "{\"remove\":{\"path\":\"a\",\"deletionVector\":{\"storageType\":\"u\"}}}"),
    no_protocol = c(good_m, add_line("a")),
    no_metadata = c(good_p, add_line("a")),
    two_protocols = c(good_p, good_p, good_m),
    two_metadata = c(good_p, good_m, good_m),
    protocol_text_version = c("{\"protocol\":{\"minReaderVersion\":\"1\",\"minWriterVersion\":2}}", good_m),
    protocol_bad_features = c("{\"protocol\":{\"minReaderVersion\":3,\"minWriterVersion\":7,\"readerFeatures\":[1]}}", good_m),
    metadata_no_id = c(good_p, "{\"metaData\":{\"schemaString\":\"{}\",\"partitionColumns\":[]}}"),
    metadata_bad_schema = c(good_p, "{\"metaData\":{\"id\":\"x\",\"schemaString\":\"{nope\",\"partitionColumns\":[]}}"),
    metadata_schema_not_struct = c(good_p, "{\"metaData\":{\"id\":\"x\",\"schemaString\":\"[]\",\"partitionColumns\":[]}}"),
    metadata_bad_partitions = c(good_p, "{\"metaData\":{\"id\":\"x\",\"schemaString\":\"{\\\"type\\\":\\\"struct\\\",\\\"fields\\\":[]}\",\"partitionColumns\":\"p\"}}"),
    metadata_bad_configuration = c(good_p, "{\"metaData\":{\"id\":\"x\",\"schemaString\":\"{\\\"type\\\":\\\"struct\\\",\\\"fields\\\":[]}\",\"partitionColumns\":[],\"configuration\":{\"a\":true}}}"),
    partition_not_in_schema = c(good_p, metadata_line(partition = "p"), add_line("a", list(p = "1"))),
    txn_without_app = c(good_p, good_m, "{\"txn\":{\"version\":1}}"),
    txn_empty_app = c(good_p, good_m, "{\"txn\":{\"appId\":\"\",\"version\":1}}"),
    txn_text_version = c(good_p, good_m, "{\"txn\":{\"appId\":\"a\",\"version\":\"1\"}}"),
    domain_without_removed = c(good_p, good_m, "{\"domainMetadata\":{\"domain\":\"d\",\"configuration\":\"{}\"}}"),
    domain_empty_name = c(good_p, good_m, "{\"domainMetadata\":{\"domain\":\"\",\"configuration\":\"{}\",\"removed\":false}}")
  )
  for (case in names(bad)) {
    path <- hand_table(bad[[case]])
    tbl <- "untouched"
    expect_error(tbl <- lake_open(path), class = "zulake_error_corrupt_log", label = case)
    expect_identical(tbl, "untouched", label = case)
  }
})

test_that("unknown actions and fields are ignored, and names match exactly", {
  # The protocol: clients must ignore unrecognised actions and fields. A key
  # that only starts with an action's name is not that action.
  path <- hand_table(c(
    protocol_line(), metadata_line(),
    "{\"additional\":{\"path\":\"not-a-file.parquet\",\"size\":1,\"partitionValues\":{}}}",
    "{\"newAction\":{\"anything\":[1,2,3]}}",
    "{\"add\":{\"path\":\"a.parquet\",\"size\":1,\"partitionValues\":{},\"modificationTime\":0,\"dataChange\":true,\"futureField\":{\"x\":1}}}",
    "{\"commitInfo\":{\"anything\":1}}",
    "{\"cdc\":{\"path\":\"_change_data/c.parquet\",\"size\":1,\"partitionValues\":{},\"dataChange\":false}}"
  ))
  tbl <- lake_open(path)
  expect_identical(tbl$files$path, "a.parquet")
  expect_identical(tbl$commit_info, list(anything = 1L))
})

test_that("an empty commit file changes nothing", {
  path <- hand_table()
  write_commit(path, 1, character())
  tbl <- lake_open(path)
  expect_identical(lake_version(tbl), 1)
  expect_identical(tbl$files$path, "part-0.parquet")
})

test_that("partition values are checked against the column's Delta type", {
  ok <- list(
    string = c("x", "1", "a/b=c%"), binary = c("\\u0001"),
    boolean = c("true", "false", "TRUE", "False"),
    byte = c("-128", "127", "0", "+5", "007"),
    short = c("-32768", "32767"),
    integer = c("-2147483648", "2147483647"),
    long = c("-9223372036854775808", "9223372036854775807", "0009223372036854775807"),
    float = c("1.5", "-0.0", "1e10", "1.0E-5", "NaN", "Infinity", "-Infinity", ".5", "3."),
    double = c("1", "-1.25e+300"),
    "decimal(10,2)" = c("12345678.90", "-0.01", "1E+3"),
    date = c("2024-01-01", "0001-01-01", "9999-12-31", "2024-1-5"),
    timestamp = c("1970-01-01 00:00:00", "1970-01-01 00:00:00.123456", "1970-01-01T00:00:00.123456Z", "2024-02-29T12:30:45Z"),
    timestamp_ntz = c("1970-01-01 00:00:00", "2024-02-29 12:30:45.123456")
  )
  bad <- list(
    boolean = c("yes", "1", "t"),
    byte = c("-129", "128", "1.0", "one", "1e2", " 1"),
    short = c("-32769", "32768"),
    integer = c("-2147483649", "2147483648", "99999999999"),
    long = c("-9223372036854775809", "9223372036854775808", "18446744073709551616", "--1"),
    float = c("one", "1,5", "1.5.5", "Inf", "e5"),
    double = c("0x10", ""[0]),
    "decimal(10,2)" = c("1,5", "abc"),
    date = c("2024-13-01", "2024-00-10", "2024-01-32", "20240101", "2024-01-01 00:00:00", "24-01-01"),
    timestamp = c("2024-01-01", "2024-01-01 25", "2024-13-01 00:00:00", "noon"),
    timestamp_ntz = c("2024-01-01T00:00:00Z", "2024-01-01")
  )
  for (type in names(ok)) {
    for (x in ok[[type]]) expect_true(zulake:::partition_value_ok(x, type), label = paste(type, x))
  }
  for (type in names(bad)) {
    for (x in bad[[type]]) expect_false(zulake:::partition_value_ok(x, type), label = paste(type, x))
  }
})

test_that("partition values are checked on the physical name under column mapping, and empty means null", {
  lines <- c(
    protocol_line(2L, 5L),
    metadata_line(
      columns = c(id = "long", p = "integer"), partition = "p",
      configuration = list(delta.columnMapping.mode = "name"), physical = c(p = "col-p")
    ),
    add_line("a.parquet", list("col-p" = "1")),
    add_line("b.parquet", list("col-p" = "")),
    add_line("c.parquet", list("col-p" = NULL))
  )
  expect_identical(lake_open(hand_table(lines))$files$path, c("a.parquet", "b.parquet", "c.parquet"))
  lines[5L] <- add_line("c.parquet", list("col-p" = "x"))
  expect_no_snapshot(lake_open(hand_table(lines)), "zulake_error_corrupt_log")
  # Without column mapping the logical name is the key, and "col-p" is not one.
  lines <- c(protocol_line(), metadata_line(c(id = "long", p = "integer"), partition = "p"), add_line("c.parquet", list(p = "x")))
  expect_no_snapshot(lake_open(hand_table(lines)), "zulake_error_corrupt_log")
})

test_that("a removed file's partition values are not checked", {
  lines <- c(protocol_line(), metadata_line(c(id = "long", p = "integer"), partition = "p"), add_line("c.parquet", list(p = "x")))
  path <- hand_table(lines)
  write_commit(path, 1, remove_line("c.parquet"))
  expect_identical(nrow(lake_open(path)$files), 0L)
  expect_no_snapshot(lake_open(path, version = 0), "zulake_error_corrupt_log")
})

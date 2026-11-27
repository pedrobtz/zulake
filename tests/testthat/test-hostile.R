# Hostile logs (design section 8): each is a classed zulake_error, and no
# snapshot is returned, or for a deletion vector no rows. The checkpoint
# ones are Stage 2b's.

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

test_that("a commit with a NUL byte is a corrupt log, and no snapshot is returned", {
  path <- hand_table()
  f <- file.path(path, "_delta_log", "00000000000000000000.json")
  bytes <- readBin(f, "raw", file.size(f))
  writeBin(c(bytes[1:10], as.raw(0L), bytes[-(1:10)]), f)
  expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
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

test_that("a _last_checkpoint past the end of the log is a corrupt log, at every version", {
  # deltalake 1.7.0 refuses the versions from 99 on ("Had a _last_checkpoint
  # hint but didn't find any checkpoints") and opens the earlier ones;
  # zulake refuses the log (design section 4.2).
  path <- fixture_table("last-checkpoint-past-log", "hostile")
  for (version in list(NULL, 3, 10, 12)) {
    expect_no_snapshot(lake_open(path, version = version), "zulake_error_corrupt_log")
  }
  # With the hint gone, the checkpoints are read: zl-checkpoint.
  copy <- local_fixture_copy("last-checkpoint-past-log", "hostile")
  unlink(file.path(copy, "_delta_log", "_last_checkpoint"))
  expect_same_state(lake_open(copy), lake_open(fixture_table("zl-checkpoint")), "hint gone")
})

test_that("a multi-part checkpoint with a part missing, which _last_checkpoint names, is a corrupt log", {
  # Part 2 of 3 is gone; _last_checkpoint names version 4 with parts = 3.
  # deltalake 1.7.0 refuses versions 4 and 5 and opens 0 to 3.
  path <- fixture_table("missing-checkpoint-part", "hostile")
  for (version in list(NULL, 3, 4, 5)) {
    expect_no_snapshot(lake_open(path, version = version), "zulake_error_corrupt_log")
  }
  err <- tryCatch(lake_open(path), error = identity)
  expect_identical(err$checkpoint, 4)
  # No part was read: the hint is checked against the listing first.
  rec <- new.env()
  storage <- recording_storage(zulake:::storage_local(path), rec)
  expect_error(zulake:::snapshot_build(storage, path), class = "zulake_error_corrupt_log")
  expect_identical(rec$calls, c("list _delta_log/", "get _delta_log/_last_checkpoint"))
  # Without commits 0 to 3 and the hint, the log has neither commit 0 nor
  # a whole checkpoint.
  copy <- local_fixture_copy("missing-checkpoint-part", "hostile")
  unlink(file.path(copy, "_delta_log", c("_last_checkpoint", sprintf("%020d.json", 0:3))))
  expect_no_snapshot(lake_open(copy), "zulake_error_checkpoint_unreadable")
  expect_identical(tryCatch(lake_open(copy), error = identity)$checkpoint, 4)
})

test_that("a _last_checkpoint that is not JSON, or has no version, is a corrupt log", {
  path <- hand_table()
  f <- file.path(path, "_delta_log", "_last_checkpoint")
  for (text in c("{\"version\":", "[1]", "{\"size\":3}", "{\"version\":-1}", "{\"version\":1.5}", "{\"version\":\"0\"}")) {
    writeLines(text, f)
    expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
  }
  writeLines("{\"version\":0,\"size\":3}", f)
  # Version 0 has no checkpoint: _last_checkpoint names one the log lacks.
  expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
  write_json_checkpoint(path, 0, readLines(file.path(path, "_delta_log", "00000000000000000000.json")))
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
    metadata_bad_partitions = c(good_p, sub("\"partitionColumns\":[]", "\"partitionColumns\":[1]", good_m, fixed = TRUE)),
    metadata_bad_configuration = c(good_p, sub("\"configuration\":{}", "\"configuration\":{\"a\":true}", good_m, fixed = TRUE)),
    metadata_schema_no_fields = c(good_p, "{\"metaData\":{\"id\":\"x\",\"schemaString\":\"{\\\"type\\\":\\\"struct\\\"}\",\"partitionColumns\":[]}}"),
    partition_not_in_schema = c(good_p, metadata_line(partition = "p"), add_line("a", list(p = "1"))),
    schema_fields_not_objects = c(good_p, "{\"metaData\":{\"id\":\"x\",\"schemaString\":\"{\\\"type\\\":\\\"struct\\\",\\\"fields\\\":[1,\\\"p\\\"]}\",\"partitionColumns\":[\"p\"]}}", add_line("a", list(p = "1"))),
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

test_that("a schema with no fields is a table with no columns", {
  meta <- "{\"metaData\":{\"id\":\"x\",\"schemaString\":\"{\\\"type\\\":\\\"struct\\\",\\\"fields\\\":[]}\",\"partitionColumns\":[]}}"
  tbl <- lake_open(hand_table(c(protocol_line(), meta)))
  expect_identical(tbl$metadata$schema$fields, list())
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
    "decimal(10,2)" = c("12345678.90", "-0.01", "+1.5", "0012", "99999999.99"),
    "decimal(4,0)" = c("9999", "-1"),
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
    float = c("one", "1,5", "1.5.5", "In", "infin", "e5"),
    double = c("0x10", ""[0]),
    # Exponents, a point without digits on one side, and values the type
    # cannot hold (#112).
    "decimal(10,2)" = c("1,5", "abc", "1E+3", "1e2", ".5", "5.", "-.5", "12.345", "123456789.00", "1.2.3", "+-1"),
    "decimal(4,0)" = c("10000", "1.0"),
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
  # A void column holds only nulls, so no value is one (#133).
  expect_false(zulake:::partition_value_ok("anything", "void"))
  expect_false(zulake:::partition_value_ok("null", "void"))
})

test_that("partition values are checked on the physical name under column mapping, and empty means null", {
  lines <- c(
    protocol_line(2L, 5L),
    metadata_line(
      columns = c(id = "long", p = "integer"), partition = "p",
      configuration = list(delta.columnMapping.mode = "name"), physical = c(id = "col-id", p = "col-p")
    ),
    add_line("a.parquet", list("col-p" = "1")),
    add_line("b.parquet", list("col-p" = "")),
    add_line("c.parquet", list("col-p" = NULL))
  )
  expect_identical(lake_open(hand_table(lines))$files$path, c("a.parquet", "b.parquet", "c.parquet"))
  lines[5L] <- add_line("c.parquet", list("col-p" = "x"))
  expect_no_snapshot(lake_open(hand_table(lines)), "zulake_error_corrupt_log")
  # Field metadata that is not an object has no physical name, which in
  # name mode is a corrupt log, never the logical name as the key (#77).
  meta <- metadata_line(c(p = "integer"), partition = "p", configuration = list(delta.columnMapping.mode = "name"))
  odd <- sub("\\\"metadata\\\":{}", "\\\"metadata\\\":\\\"x\\\"", meta, fixed = TRUE)
  expect_false(identical(odd, meta))
  lines <- c(protocol_line(2L, 5L), odd, add_line("a.parquet", list(p = "1")))
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

test_that("a compaction file that does not end after it starts is not a log file (#69)", {
  # The protocol names <x>.<y>.compacted.json only for y > x; any other is
  # left out of the log, as deltalake 1.7.0 opens the table.
  path <- local_fixture_copy("zl-log-compaction")
  dir <- file.path(path, "_delta_log")
  writeLines("not json", file.path(dir, "00000000000000000002.00000000000000000002.compacted.json"))
  writeLines("not json", file.path(dir, "00000000000000000004.00000000000000000001.compacted.json"))
  for (version in oracle_versions("zl-log-compaction")) {
    expect_oracle(replay_files_frame(lake_open(path, version = version), "path"), "zl-log-compaction", version, "add_actions")
  }
  expect_false(any(grepl("00000000000000000002.00000000000000000002", lake_log(lake_open(path))$name, fixed = TRUE)))
  expect_false(any(grepl("00000000000000000004.00000000000000000001", lake_log(lake_open(path))$name, fixed = TRUE)))
})

test_that("an unreadable compaction file is passed over for the commits it covers (#69)", {
  path <- local_fixture_copy("zl-log-compaction")
  compacted <- file.path(path, "_delta_log", "00000000000000000001.00000000000000000003.compacted.json")
  writeLines("not json", compacted)
  for (version in oracle_versions("zl-log-compaction")) {
    expect_oracle(replay_files_frame(lake_open(path, version = version), "path"), "zl-log-compaction", version, "add_actions")
  }
  # Without one of the commits it covers, it is needed, and a corrupt log.
  unlink(file.path(path, "_delta_log", "00000000000000000002.json"))
  for (version in 3:5) expect_no_snapshot(lake_open(path, version = version), "zulake_error_corrupt_log")
  expect_oracle(replay_files_frame(lake_open(path, version = 1), "path"), "zl-log-compaction", 1, "add_actions")
  # An authentication failure is never passed over.
  storage <- zulake:::storage_local(fixture_table("zl-log-compaction"))
  local <- storage
  storage$local_path <- NULL
  storage$get <- function(p) {
    if (grepl("compacted", p, fixed = TRUE)) zulake:::zulake_abort("auth", "refused", status = 403L)
    local$get(p)
  }
  expect_no_snapshot(zulake:::snapshot_build(storage, "t"), "zulake_error_auth")
})

test_that("a hole in the commits is a corrupt log, not a cleaned-up version (#70)", {
  path <- local_fixture_copy("zl-checkpoint")
  unlink(file.path(path, "_delta_log", "00000000000000000003.json"))
  for (version in 3:4) {
    expect_no_snapshot(lake_open(path, version = version), "zulake_error_corrupt_log")
  }
  for (version in c(0:2, 5:12)) {
    expect_oracle(replay_files_frame(lake_open(path, version = version), "path"), "zl-checkpoint", version, "add_actions")
  }
  # Cleaned from the start, a version before the checkpoint is gone.
  unlink(file.path(path, "_delta_log", sprintf("%020d.json", 0:2)))
  for (version in 0:4) {
    expect_no_snapshot(lake_open(path, version = version), "zulake_error_version")
  }
})

test_that("a partition column of a nested type is a corrupt log", {
  schema <- "{\\\"type\\\":\\\"struct\\\",\\\"fields\\\":[{\\\"name\\\":\\\"p\\\",\\\"type\\\":{\\\"type\\\":\\\"struct\\\",\\\"fields\\\":[]},\\\"nullable\\\":true,\\\"metadata\\\":{}}]}"
  meta <- sprintf("{\"metaData\":{\"id\":\"x\",\"schemaString\":\"%s\",\"partitionColumns\":[\"p\"],\"configuration\":{}}}", schema)
  path <- hand_table(c(protocol_line(), meta, add_line("a.parquet", list(p = "1"))))
  expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
})

test_that("an in-commit timestamp enablement version that is not a whole number is a corrupt log", {
  path <- local_fixture_copy("zl-catalog-managed")
  f1 <- file.path(path, "_delta_log", "00000000000000000001.json")
  lines <- readLines(f1)
  lines[2L] <- protocol_line(1L, 7L, writer_features = "inCommitTimestamp")
  lines[3L] <- sub("\"delta.inCommitTimestampEnablementVersion\":\"1\"", "\"delta.inCommitTimestampEnablementVersion\":\"one\"", lines[3L], fixed = TRUE)
  writeLines(lines, f1)
  expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
  expect_no_snapshot(lake_open(path, timestamp = Sys.time()), "zulake_error_corrupt_log")
})

test_that("a randomly corrupted commit gives a snapshot or a zulake_error, never another error", {
  withr::local_seed(20261126)
  src <- fixture_table("zl-partitioned")
  for (version in c(0, 1)) {
    original <- readBin(file.path(src, "_delta_log", sprintf("%020d.json", version)), "raw", 1e6)
    for (i in seq_len(test_iterations(150L, 30L))) {
      path <- local_fixture_copy("zl-partitioned")
      bytes <- original
      at <- sample.int(length(bytes), sample(1:3, 1L))
      op <- sample(c("flip", "drop", "byte"), 1L)
      bytes <- switch(op,
        flip = {
          bytes[at] <- xor(bytes[at], as.raw(sample(1:255, length(at), TRUE)))
          bytes
        },
        drop = bytes[-at],
        byte = {
          bytes[at] <- charToRaw(paste(sample(strsplit("{}[]\":,0-9ne", "")[[1L]], length(at), TRUE), collapse = ""))[seq_along(at)]
          bytes
        }
      )
      writeBin(bytes, file.path(path, "_delta_log", sprintf("%020d.json", version)))
      res <- tryCatch(lake_open(path), error = identity)
      ok <- inherits(res, "zulake_table") || inherits(res, "zulake_error")
      expect_true(ok, label = paste(version, i, op, if (inherits(res, "error")) conditionMessage(res) else ""))
    }
  }
})

test_that("a commit with one value changed to another JSON type gives a snapshot or a zulake_error", {
  withr::local_seed(26112026)
  for (table in c("zl-partitioned", "deletion_vectors", "zl-domains", "table_with_column_mapping")) {
    src <- fixture_table(table)
    last <- max(oracle_versions(table))
    for (i in seq_len(test_iterations(120L, 25L))) {
      path <- local_fixture_copy(table)
      version <- sample(0:last, 1L)
      f <- file.path(path, "_delta_log", sprintf("%020d.json", version))
      lines <- readLines(f, warn = FALSE, encoding = "UTF-8")
      j <- sample.int(length(lines), 1L)
      lines[j] <- zujson::json_write(mutate_json(zujson::json_parse(lines[j])), auto_unbox = TRUE)
      writeLines(lines, f, useBytes = TRUE)
      res <- tryCatch(lake_open(path), error = identity)
      ok <- inherits(res, "zulake_table") || inherits(res, "zulake_error")
      expect_true(ok, label = paste(table, version, j, lines[j], if (inherits(res, "error")) conditionMessage(res) else ""))
    }
  }
})

test_that("a deletion vector with a bad CRC-32, a wrong magic number or a size past its file is a corrupt log, and no rows are returned", {
  skip_if_not_installed("zuroar")
  for (name in c("dv-bad-checksum", "dv-bad-magic", "dv-size-past-file")) {
    tbl <- lake_open(fixture_table(name, "hostile"))
    # The log itself is whole: the snapshot opens and counts from the log.
    expect_identical(lake_count(tbl), 8)
    expect_identical(nrow(lake_deletion_vectors(tbl, rows = FALSE)), 1L)
    called <- FALSE
    for (f in list(function() lake_read(tbl), function() lake_deletion_vectors(tbl),
                   function() lake_walk(tbl, function(p) called <<- TRUE),
                   function() lake_read(tbl, columns = character()))) {
      err <- tryCatch(f(), error = identity)
      expect_s3_class(err, "zulake_error_corrupt_log")
      expect_s3_class(err, "zulake_error")
      expect_identical(err$file, lake_files(tbl, stats = FALSE)$path, label = name)
    }
    expect_false(called)
  }
  msg <- function(name) conditionMessage(tryCatch(lake_read(lake_open(fixture_table(name, "hostile"))), error = identity))
  expect_match(msg("dv-bad-checksum"), "CRC-32", fixed = TRUE)
  expect_match(msg("dv-size-past-file"), "past the end", fixed = TRUE)
  # The wrong magic number is behind a checksum that no longer matches; with
  # the checksum made right for it, the magic number is what refuses it.
  path <- local_fixture_copy("dv-bad-magic", "hostile")
  f <- list.files(path, pattern = "^deletion_vector_", full.names = TRUE)
  b <- readBin(f, "raw", file.size(f))
  b[42:45] <- be_bytes(test_crc32(b[6:41]))
  writeBin(b, f)
  err <- tryCatch(lake_read(lake_open(path)), error = identity)
  expect_s3_class(err, "zulake_error_corrupt_log")
  expect_match(conditionMessage(err), "magic number", fixed = TRUE)
})

test_that("any one byte of a deletion vector file changed, or the file cut short, is a corrupt log", {
  skip_if_not_installed("zuroar")
  path <- local_fixture_copy("table-with-dv-small")
  f <- list.files(path, pattern = "^deletion_vector_", full.names = TRUE)
  good <- readBin(f, "raw", file.size(f))
  tbl <- lake_open(path)
  want <- lake_read(tbl)
  for (i in seq_along(good)) {
    for (flip in c(0x01, 0x80)) {
      b <- good
      b[i] <- xor(b[i], as.raw(flip))
      writeBin(b, f)
      res <- tryCatch(lake_read(tbl), error = identity)
      expect_s3_class(res, "zulake_error_corrupt_log")
    }
  }
  for (n in seq_len(length(good) - 1L) - 1L) {
    writeBin(good[seq_len(n)], f)
    expect_error(lake_read(tbl), class = "zulake_error_corrupt_log", label = n)
  }
  writeBin(good, f)
  expect_identical(lake_read(tbl), want)
})

test_that("a log path that decodes to a NUL or to bytes that are not UTF-8 is a corrupt log (#49)", {
  for (path in c("a%00b.parquet", "e%C3%28f.parquet", "x%FF.parquet", "file:///tmp/a%00b.parquet")) {
    tbl <- lake_open(hand_table(c(protocol_line(), metadata_line(), add_line(path))))
    if (!startsWith(path, "file:")) expect_error(lake_files(tbl), class = "zulake_error_corrupt_log", label = path)
    expect_error(lake_read(tbl), class = "zulake_error_corrupt_log", label = path)
  }
  # A "%" that is not an escape is kept as it is, as deltalake 1.7.0 keeps
  # it; an escape of UTF-8 bytes is decoded.
  tbl <- lake_open(hand_table(c(protocol_line(), metadata_line(), add_line("a%ZZb.parquet"), add_line("c%C3%A9.parquet"))))
  expect_identical(basename(lake_files(tbl)$uri), c("a%ZZb.parquet", "cé.parquet"))
  # A V2 sidecar path the same way.
  expect_error(percent_decode("s%00.parquet"), class = "zulake_error_corrupt_log")
})

test_that("a name-mode field without a physical name is a corrupt log naming it (#77)", {
  # Commit 0's schema lost the physical name of `letter`; commit 2 writes
  # the schema again with it. Versions 0 and 1 are refused, 2 and 3 read
  # as column_mapping does.
  path <- fixture_table("column-mapping-no-physical-name", "hostile")
  for (version in list(0, 1)) {
    expect_no_snapshot(lake_open(path, version = version), "zulake_error_corrupt_log")
    err <- tryCatch(lake_open(path, version = version), error = identity)
    expect_identical(err$column, "letter")
    expect_match(conditionMessage(err), "\"letter\"", fixed = TRUE)
  }
  for (version in 2:3) {
    tbl <- lake_open(path, version = version)
    expect_oracle(replay_files_frame(tbl, "path"), "column_mapping", version, "add_actions")
    expect_identical(lake_read(tbl), lake_read(lake_open(fixture_table("column_mapping"), version = version)))
  }
  # Every field is checked, a partition column, a field whose metadata is
  # not an object and a physical name that is not a string too, and each
  # is refused by its own name.
  for (case in list(
    list(physical = c(id = "col-id"), column = "p"),
    list(physical = c(p = "col-p"), column = "id")
  )) {
    lines <- c(
      protocol_line(2L, 5L),
      metadata_line(c(id = "long", p = "integer"), partition = "p",
                    configuration = list(delta.columnMapping.mode = "name"), physical = case$physical)
    )
    err <- tryCatch(lake_open(hand_table(lines)), error = identity)
    expect_s3_class(err, "zulake_error_corrupt_log")
    expect_identical(err$column, case$column)
  }
  meta <- metadata_line(c(id = "long"), configuration = list(delta.columnMapping.mode = "name"), physical = c(id = "col-id"))
  expect_identical(lake_open(hand_table(c(protocol_line(2L, 5L), meta)))$column_mapping, "name")
  for (bad in c('""', "1", "null", "{}")) {
    odd <- sub('\\"col-id\\"', gsub('"', '\\\\"', bad), meta, fixed = TRUE)
    expect_false(identical(odd, meta))
    expect_no_snapshot(lake_open(hand_table(c(protocol_line(2L, 5L), odd))), "zulake_error_corrupt_log")
  }
  # Without column mapping no physical name is needed.
  expect_identical(lake_version(lake_open(hand_table(c(protocol_line(2L, 5L), metadata_line())))), 0)
})

# ---- a repeated key (#102) ---------------------------------------------------

test_that("an add with a repeated key is a corrupt log at every version that replays it (#102)", {
  # zujson's lookup would take the first `path`, deltalake 1.7.0 the last.
  path <- fixture_table("duplicate-key-in-add", "hostile")
  for (version in list(NULL, 2, 3, 4)) {
    expect_no_snapshot(lake_open(path, version = version), "zulake_error_corrupt_log")
  }
  err <- tryCatch(lake_open(path), error = identity)
  expect_identical(err$file, "00000000000000000002.json")
  expect_identical(err$line, 2L)
  expect_identical(err$key, "path")
  expect_match(conditionMessage(err), "line 2 of log file \"00000000000000000002.json\"", fixed = TRUE)
  expect_match(conditionMessage(err), "\"path\" twice", fixed = TRUE)
  for (version in 0:1) {
    expect_oracle(replay_files_frame(lake_open(path, version = version), "path"), "zl-basic", version, "add_actions")
  }
})

test_that("two actions under one key on a line are a corrupt log (#102)", {
  path <- fixture_table("duplicate-action-key", "hostile")
  for (version in list(NULL, 2, 4)) {
    expect_no_snapshot(lake_open(path, version = version), "zulake_error_corrupt_log")
  }
  err <- tryCatch(lake_open(path), error = identity)
  expect_identical(err[c("file", "line", "key")], list(file = "00000000000000000002.json", line = 3L, key = "remove"))
  expect_oracle(replay_files_frame(lake_open(path, version = 1), "path"), "zl-basic", 1, "add_actions")
})

test_that("a key repeated in partitionValues or tags is a corrupt log, and the same commit without it opens (#102)", {
  meta <- metadata_line(c(id = "long", p = "string"), partition = "p")
  cases <- list(
    p = c('"partitionValues":{"p":"1","p":"2"}', '"partitionValues":{"p":"1"}'),
    k = c('"partitionValues":{"p":"1"},"tags":{"k":"a","k":"b"}', '"partitionValues":{"p":"1"},"tags":{"k":"a","K":"b"}'),
    # Keys are compared once unescaped.
    path = c('"pa\\u0074h":"c.parquet","partitionValues":{"p":"1"}', '"partitionValues":{"p":"1"},"tags":{"path":"c"}')
  )
  for (key in names(cases)) {
    lines <- sprintf('{"add":{"path":"b.parquet",%s,"size":1,"modificationTime":0,"dataChange":true}}', cases[[key]])
    path <- hand_table(c(protocol_line(), meta, add_line("a.parquet", list(p = "0"))))
    write_commit(path, 1, c(add_line("z.parquet", list(p = "0")), "", lines[1L]))
    expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
    err <- tryCatch(lake_open(path), error = identity)
    # The line in the file, counting the blank one.
    expect_identical(err[c("file", "line", "key")], list(file = "00000000000000000001.json", line = 3L, key = key), label = key)
    expect_identical(lake_open(path, version = 0)$files$path, "a.parquet")
    # The differential: the same commit with distinct keys opens.
    write_commit(path, 1, c(add_line("z.parquet", list(p = "0")), "", lines[2L]))
    expect_identical(sort(lake_open(path)$files$path), c("a.parquet", "b.parquet", "z.parquet"), label = key)
  }
})

test_that("a repeated key is found in a line with a 64-bit integer, and at any depth (#102)", {
  path <- hand_table()
  write_commit(path, 1, '{"add":{"path":"b.parquet","partitionValues":{},"size":9007199254740993,"size":1,"modificationTime":0,"dataChange":true}}')
  expect_identical(tryCatch(lake_open(path), error = identity)$key, "size")
  write_commit(path, 1, '{"commitInfo":{"operationParameters":{"x":[{"a":{"deep":1,"deep":2}}]}}}')
  expect_identical(tryCatch(lake_open(path), error = identity)$key, "deep")
  write_commit(path, 1, '{"commitInfo":{"a":{"x":1},"b":{"x":1},"c":[{"x":1},{"x":2}]}}')
  expect_identical(lake_open(path)$files$path, "part-0.parquet")
})

test_that("a _last_checkpoint with a repeated key is a corrupt log (#102)", {
  # The protocol calls it invalid.
  path <- hand_table()
  write_json_checkpoint(path, 0, readLines(file.path(path, "_delta_log", "00000000000000000000.json")))
  f <- file.path(path, "_delta_log", "_last_checkpoint")
  writeLines('{"version":0,"size":3,"size":4}', f)
  expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
  err <- tryCatch(lake_open(path), error = identity)
  expect_identical(err[c("file", "key")], list(file = "_last_checkpoint", key = "size"))
  writeLines('{"version":0,"size":3}', f)
  expect_identical(lake_open(path)$last_checkpoint[["size"]], 3L)
})

test_that("a compaction file with a repeated key is passed over for its commits, and refused when needed (#102)", {
  path <- local_fixture_copy("zl-log-compaction")
  name <- "00000000000000000001.00000000000000000003.compacted.json"
  f <- file.path(path, "_delta_log", name)
  lines <- readLines(f, warn = FALSE, encoding = "UTF-8")
  j <- which(startsWith(lines, "{\"add\":{"))[1L]
  lines[j] <- sub("{\"add\":{", "{\"add\":{\"size\":1,", lines[j], fixed = TRUE)
  writeLines(lines, f, useBytes = TRUE)
  for (version in oracle_versions("zl-log-compaction")) {
    expect_oracle(replay_files_frame(lake_open(path, version = version), "path"), "zl-log-compaction", version, "add_actions")
  }
  unlink(file.path(path, "_delta_log", "00000000000000000002.json"))
  for (version in 3:5) expect_no_snapshot(lake_open(path, version = version), "zulake_error_corrupt_log")
  err <- tryCatch(lake_open(path), error = identity)
  expect_identical(err[c("file", "line", "key")], list(file = name, line = j, key = "size"))
})

test_that("a JSON V2 checkpoint with a repeated key is passed over, and unreadable when needed (#102)", {
  path <- hand_table()
  write_commit(path, 1, add_line("part-1.parquet"))
  name <- write_json_checkpoint(path, 1, c(
    protocol_line(3L, 7L, "v2Checkpoint", "v2Checkpoint"), metadata_line(),
    add_line("part-0.parquet"), sub("{\"add\":{", "{\"add\":{\"path\":\"part-9.parquet\",", add_line("part-1.parquet"), fixed = TRUE)
  ))
  expect_identical(lake_open(path)$files$path, c("part-0.parquet", "part-1.parquet"))
  unlink(file.path(path, "_delta_log", "00000000000000000000.json"))
  err <- tryCatch(lake_open(path), error = identity)
  expect_s3_class(err, "zulake_error_checkpoint_unreadable")
  cause <- err$parent
  while (!is.null(cause) && !inherits(cause, "zulake_error_corrupt_log")) cause <- cause$parent
  expect_identical(cause[c("file", "line", "key")], list(file = basename(name), line = 4L, key = "path"))
})

test_that("a key repeated in a random object of a random commit is refused there (#102)", {
  withr::local_seed(20261127)
  tables <- Filter(function(t) {
    log <- list.files(file.path(fixture_table(t), "_delta_log"), pattern = "^[0-9]{20}[.]json$")
    length(log) == max(oracle_versions(t)) + 1L
  }, fixture_names("tables"))
  for (i in seq_len(test_iterations(60L, 15L))) {
    table <- sample(tables, 1L)
    path <- local_commits_only(table)
    unlink(list.files(file.path(path, "_delta_log"), pattern = "compacted", full.names = TRUE))
    version <- sample(oracle_versions(table), 1L)
    name <- sprintf("%020d.json", version)
    f <- file.path(path, "_delta_log", name)
    lines <- readLines(f, warn = FALSE, encoding = "UTF-8")
    j <- sample.int(length(lines), 1L)
    n <- length(gregexpr("{\"", lines[j], fixed = TRUE)[[1L]])
    hit <- repeat_key_at(lines[j], sample.int(n, 1L))
    if (is.null(hit)) next
    lines[j] <- hit$line
    writeLines(lines, f, useBytes = TRUE)
    err <- tryCatch(lake_open(path), error = identity)
    label <- paste(table, version, j, hit$key)
    expect_s3_class(err, "zulake_error_corrupt_log")
    expect_identical(err[c("file", "line", "key")], list(file = name, line = j, key = hit$key), label = label)
  }
})

# ---- an add and a remove of one file in one commit (#103) ---------------------

test_that("a commit that adds and removes one file is a corrupt log, in either order (#103)", {
  # deltalake 1.7.0 keeps the first line's action; the protocol forbids both.
  file <- "part-00000-e10fff6f-4360-42ee-8090-3f777493cca7-c000.snappy.parquet"
  for (name in c("add-then-remove-same-file", "remove-then-add-same-file")) {
    path <- fixture_table(name, "hostile")
    for (version in list(NULL, 2, 3, 4)) {
      expect_no_snapshot(lake_open(path, version = version), "zulake_error_corrupt_log")
    }
    err <- tryCatch(lake_open(path), error = identity)
    expect_identical(err[c("file", "path")], list(file = "00000000000000000002.json", path = file), label = name)
    expect_match(conditionMessage(err), "both adds and removes", fixed = TRUE)
    expect_oracle(replay_files_frame(lake_open(path, version = 1), "path"), "zl-basic", 1, "add_actions")
  }
})

test_that("a commit that removes a file and adds it with a new deletion vector opens (#103)", {
  dv <- list(storageType = "u", pathOrInlineDv = "vBn[lx{q8@P<9BNH/isA", offset = 1L, sizeInBytes = 36L, cardinality = 2L)
  path <- hand_table(c(protocol_line(3L, 7L, "deletionVectors", "deletionVectors"), metadata_line(), add_line("a.parquet")))
  for (lines in list(c(remove_line("a.parquet"), add_line("a.parquet", dv = dv)), c(add_line("a.parquet", dv = dv), remove_line("a.parquet")))) {
    write_commit(path, 1, lines)
    files <- lake_files(lake_open(path))
    expect_identical(files$path, "a.parquet")
    expect_identical(files$action[[1L]]$deletionVector$pathOrInlineDv, dv$pathOrInlineDv)
  }
  # The same tuple twice, with a deletion vector, is refused.
  write_commit(path, 1, c(add_line("a.parquet", dv = dv), remove_line("a.parquet", dv = dv)))
  expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
})

test_that("zujson keeps every member of an object under its decoded name, which the repeated-key check needs (#102)", {
  # If zujson's default ever collapsed repeated keys, zulake's check (a walk
  # over what zujson returns) would see none: this pins the contract.
  text <- '{"a":1,"a\\u0062":{"ab":2},"ab":[{"c":1,"c":2}]}'
  for (x in list(zujson::json_parse(text), zujson::json_parse_raw(charToRaw(text)), zujson::json_parse_ndjson(text)[[1L]])) {
    expect_identical(names(x), c("a", "ab", "ab"))
    expect_identical(names(x[[3L]][[1L]]), c("c", "c"))
  }
})

# ---- two adds, or two removes, of one path in one commit (#106) -------------

test_that("a commit with two adds, or two removes, of one path is a corrupt log, whatever the deletion vectors (#106)", {
  # deltalake 1.7.0 opens all three (design section 4.2). Unrefused, the
  # two adds of one path under two deletion vectors are two live files, and
  # the file is read twice.
  e10 <- "part-00000-e10fff6f-4360-42ee-8090-3f777493cca7-c000.snappy.parquet"
  dv <- "part-00000-fae5310a-a37d-4e51-827b-c3d5516560ca-c000.snappy.parquet"
  cases <- list(
    "two-adds-same-file" = list(table = "zl-basic", commit = 2, versions = list(NULL, 2, 3, 4), path = e10, what = "adds", before = 1),
    "two-removes-same-file" = list(table = "zl-basic", commit = 3, versions = list(NULL, 3, 4), path = e10, what = "removes", before = 2),
    "two-adds-same-path-new-dv" = list(table = "table-with-dv-small", commit = 1, versions = list(NULL, 1), path = dv, what = "adds", before = 0)
  )
  for (name in names(cases)) {
    case <- cases[[name]]
    path <- fixture_table(name, "hostile")
    for (version in case$versions) {
      expect_no_snapshot(lake_open(path, version = version), "zulake_error_corrupt_log")
    }
    err <- tryCatch(lake_open(path), error = identity)
    expect_identical(err[c("file", "path")], list(file = sprintf("%020d.json", case$commit), path = case$path), label = name)
    expect_match(conditionMessage(err), sprintf("%s \"%s\" twice", case$what, case$path), fixed = TRUE, label = name)
    tbl <- lake_open(path, version = case$before)
    expect_oracle(replay_files_frame(tbl, "path"), case$table, case$before, "add_actions")
    expect_oracle(lake_count(tbl), case$table, case$before, "count")
  }
})

test_that("two adds of one path are refused even when they are the same action, and across commits they are not (#106)", {
  dv <- list(storageType = "u", pathOrInlineDv = "vBn[lx{q8@P<9BNH/isA", offset = 1L, sizeInBytes = 36L, cardinality = 2L)
  path <- hand_table(c(protocol_line(3L, 7L, "deletionVectors", "deletionVectors"), metadata_line(), add_line("a.parquet")))
  refused <- list(
    adds = c(add_line("b.parquet"), add_line("b.parquet")),
    removes = c(remove_line("a.parquet"), remove_line("a.parquet")),
    removes = c(remove_line("a.parquet"), remove_line("a.parquet", dv = dv))
  )
  for (i in seq_along(refused)) {
    write_commit(path, 1, refused[[i]])
    err <- tryCatch(lake_open(path), error = identity)
    expect_s3_class(err, "zulake_error_corrupt_log")
    expect_identical(err[c("file", "path")], list(file = "00000000000000000001.json", path = if (i == 1L) "b.parquet" else "a.parquet"))
    expect_match(conditionMessage(err), names(refused)[i], fixed = TRUE)
  }
  # One add of a path per commit, in two commits: the second replaces it.
  write_commit(path, 1, add_line("b.parquet", size = 1))
  write_commit(path, 2, add_line("b.parquet", size = 2))
  files <- lake_files(lake_open(path))
  expect_identical(files$path, c("a.parquet", "b.parquet"))
  expect_identical(files$size_bytes[files$path == "b.parquet"], 2)
})

test_that("a compaction file with two adds of one file is a corrupt log when needed, and a checkpoint is not checked (#106, #117)", {
  path <- local_fixture_copy("zl-log-compaction")
  name <- "00000000000000000001.00000000000000000003.compacted.json"
  f <- file.path(path, "_delta_log", name)
  lines <- readLines(f, warn = FALSE, encoding = "UTF-8")
  j <- which(startsWith(lines, "{\"add\":{"))[1L]
  writeLines(append(lines, lines[j], after = j), f, useBytes = TRUE)
  # Passed over for the commits it covers while they are all in the log.
  expect_oracle(replay_files_frame(lake_open(path), "path"), "zl-log-compaction", 5, "add_actions")
  unlink(file.path(path, "_delta_log", "00000000000000000002.json"))
  err <- tryCatch(lake_open(path), error = identity)
  expect_s3_class(err, "zulake_error_corrupt_log")
  expect_identical(err$file, name)
  expect_identical(err$path, zujson::json_parse(lines[j])$add$path)
  # A checkpoint is the reconciled state: replay keeps one of the two.
  path <- hand_table()
  write_commit(path, 1, add_line("part-1.parquet"))
  write_json_checkpoint(path, 1, c(
    protocol_line(3L, 7L, "v2Checkpoint", "v2Checkpoint"), metadata_line(),
    add_line("part-0.parquet"), add_line("part-1.parquet"), add_line("part-1.parquet")
  ))
  unlink(file.path(path, "_delta_log", "00000000000000000000.json"))
  expect_identical(lake_open(path)$files$path, c("part-0.parquet", "part-1.parquet"))
})

# ---- a repeated key in stats and schemaString (#107) -------------------------

test_that("statistics with a repeated key are a corrupt log where they are used (#107)", {
  # Unrefused, the first `maxValues` (id 11), or the first `id` of
  # `minValues` (13), would prune the file for `id == 12`.
  file <- "part-00000-08a25d6d-31b9-4a28-aeb4-7dc9520ede42-c000.snappy.parquet"
  for (case in list(c("stats-repeated-key", "maxValues"), c("stats-repeated-column", "id"))) {
    path <- fixture_table(case[1L], "hostile")
    tbl <- lake_open(path)
    for (err in list(tryCatch(lake_files(tbl), error = identity), tryCatch(lake_read(tbl, filter = id == 12), error = identity))) {
      expect_s3_class(err, "zulake_error_corrupt_log")
      expect_identical(err[c("file", "key")], list(file = file, key = case[2L]), label = case[1L])
      expect_match(conditionMessage(err), sprintf("the statistics of file \"%s\" have an object with the key \"%s\" twice", file, case[2L]), fixed = TRUE)
    }
    # Before commit 4 the statistics are zl-basic's.
    tbl <- lake_open(path, version = 3)
    expect_oracle(lake_read(tbl, filter = id >= 0), "zl-basic", 3, "read")
  }
})

test_that("a schemaString with a repeated key is a corrupt log, and other JSON in strings is not checked (#107)", {
  path <- fixture_table("schema-repeated-key", "hostile")
  for (version in list(NULL, 0, 4)) {
    expect_no_snapshot(lake_open(path, version = version), "zulake_error_corrupt_log")
  }
  err <- tryCatch(lake_open(path), error = identity)
  expect_identical(err[c("file", "action", "key")], list(file = "00000000000000000000.json", action = "metaData", key = "type"))
  expect_match(conditionMessage(err), "`schemaString` has an object with the key \"type\" twice", fixed = TRUE)
  # A tag holding JSON text is a string, not checked.
  path <- hand_table()
  write_commit(path, 1, '{"add":{"path":"b.parquet","partitionValues":{},"size":1,"modificationTime":0,"dataChange":true,"tags":{"t":"{\\"a\\":1,\\"a\\":2}"}}}')
  expect_identical(lake_files(lake_open(path))$path, c("b.parquet", "part-0.parquet"))
})

# ---- a repeated key in a Parquet checkpoint MAP (#108) -----------------------

test_that("a Parquet checkpoint whose MAP repeats a key is passed over, and unreadable when needed (#108)", {
  # The first add of the checkpoint at 2 has partitionValues [x: 1, x: 2].
  table <- "zl-checkpoint-no-last"
  path <- fixture_table("checkpoint-map-repeated-key", "hostile")
  for (version in oracle_versions(table)) {
    tbl <- lake_open(path, version = version)
    answer <- oracle_field(table, version, "add_actions")
    expect_oracle(replay_files_frame(tbl, names(answer$columns)), table, version, "add_actions")
    expect_oracle(lake_count(tbl), table, version, "count")
    expect_oracle(lake_read(tbl), table, version, "read")
    expect_identical(tbl$metadata[["id"]], oracle_field(table, version, c("metadata", "id")))
    expect_same_state(tbl, lake_open(fixture_table(table), version = version), paste(table, version))
  }
  copy <- local_fixture_copy("checkpoint-map-repeated-key", "hostile")
  unlink(file.path(copy, "_delta_log", "00000000000000000000.json"))
  for (version in list(NULL, 2, 3)) {
    expect_no_snapshot(lake_open(copy, version = version), "zulake_error_checkpoint_unreadable")
  }
  err <- tryCatch(lake_open(copy), error = identity)
  expect_identical(err$checkpoint, 2)
  # A refusal of the checkpoint, not a corrupt log, is the cause.
  cause <- err$parent
  while (!is.null(cause) && !inherits(cause, "zulake_checkpoint_refusal")) cause <- cause$parent
  expect_false(is.null(cause))
  expect_false(inherits(cause, "zulake_error"))
  expect_match(conditionMessage(cause), "a map holds the key \"x\" twice", fixed = TRUE)
  expect_match(conditionMessage(err), "a map holds the key \"x\" twice", fixed = TRUE)
})

test_that("a decimal partition value the comparator cannot read or the type cannot hold is a corrupt log (#112)", {
  # The oracle: deltalake 1.7.0 refuses each of these logs
  # (fixtures/hostile-answers.json, written by tools/oracle/answers.py).
  answers <- zujson::json_parse_file(testthat::test_path("fixtures", "hostile-answers.json"))
  values <- c(
    "decimal-partition-no-integer-digit" = ".5",
    "decimal-partition-no-fraction-digit" = "5.",
    "decimal-partition-negative-no-integer-digit" = "-.5",
    "decimal-partition-exponent" = "1e2",
    "decimal-partition-past-scale" = "12.345",
    "decimal-partition-past-precision" = "123456789.00",
    "decimal-partition-past-precision-small" = "123.45"
  )
  expect_setequal(names(values), grep("^decimal-partition-", fixture_names("hostile"), value = TRUE))
  for (name in names(values)) {
    refusal <- answers[[name]]$refusal
    expect_false(is.null(refusal), label = name)
    expect_match(refusal$message, sprintf("Failed to parse value '%s'", values[[name]]), fixed = TRUE, label = name)
    path <- fixture_table(name, "hostile")
    expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
    err <- tryCatch(lake_open(path), error = identity)
    expect_match(conditionMessage(err), sprintf("partition value \"%s\"", values[[name]]), fixed = TRUE, label = name)
    expect_identical(err$column, if (endsWith(name, "-small")) "pd4" else "pdec", label = name)
  }
  # Spellings the comparator reads and the type holds open and compare
  # exactly, fewer fraction digits than the scale too (deltalake refuses
  # those; their value is not in doubt).
  for (value in c("+12.30", "012.30", "12.3", "12", "-0.00", "99999999.99")) {
    path <- local_fixture_copy("zl-decimal-partitions")
    f <- file.path(path, "_delta_log", "00000000000000000000.json")
    lines <- readLines(f, warn = FALSE)
    lines <- sub('"pdec":"12.30"', sprintf('"pdec":"%s"', value), lines, fixed = TRUE)
    writeLines(lines, f)
    tbl <- lake_open(path)
    rows <- lake_read(tbl)
    v <- as.numeric(value)
    expect_identical(rows$pdec[rows$id == 0], v, label = value)
    for (expr in list(bquote(pdec == .(v)), bquote(pdec %in% .(v)), quote(pdec > -1000), bquote(pdec <= .(v)))) {
      expect_identical(eval(bquote(lake_read(tbl, filter = .(expr)))), r_subset(rows, expr), ignore_attr = TRUE,
                       label = paste(value, deparse(expr)))
    }
  }
})

# ---- two actions on one line (#121) ------------------------------------------

test_that("a line holding two actions is a corrupt log naming the file and the line (#121)", {
  # deltalake 1.7.0 opens it and applies the add alone; zulake applied both.
  expect_null(hostile_refusal("two-actions-one-line"))
  path <- fixture_table("two-actions-one-line", "hostile")
  for (version in list(NULL, 2, 3, 4)) {
    expect_no_snapshot(lake_open(path, version = version), "zulake_error_corrupt_log")
  }
  err <- tryCatch(lake_open(path), error = identity)
  expect_identical(err[c("file", "line")], list(file = "00000000000000000002.json", line = 2L))
  expect_match(conditionMessage(err), "line 2 of log file \"00000000000000000002.json\" holds the actions \"add\" and \"remove\"", fixed = TRUE)
  expect_oracle(replay_files_frame(lake_open(path, version = 1), "path"), "zl-basic", 1, "add_actions")
  # Any two keys on a line, known actions or not; one unknown action alone
  # is still ignored.
  path <- hand_table(c(protocol_line(), metadata_line(), "{\"add\":{\"path\":\"a\",\"size\":1,\"partitionValues\":{}},\"newAction\":{}}"))
  expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
  path <- hand_table(c(protocol_line(), metadata_line(), "{\"newAction\":{}}", add_line("a")))
  expect_identical(lake_open(path)$files$path, "a")
})

test_that("a compaction file or a JSON V2 checkpoint with two actions on a line is passed over, and refused when needed (#121)", {
  path <- local_fixture_copy("zl-log-compaction")
  name <- "00000000000000000001.00000000000000000003.compacted.json"
  f <- file.path(path, "_delta_log", name)
  lines <- readLines(f, warn = FALSE, encoding = "UTF-8")
  stopifnot(startsWith(lines[1L], "{\"add\":{"), endsWith(lines[1L], "}}"))
  lines[1L] <- sub("}$", ",\"txn\":{\"appId\":\"a\",\"version\":1}}", lines[1L])
  writeLines(lines, f, useBytes = TRUE)
  for (version in oracle_versions("zl-log-compaction")) {
    expect_oracle(replay_files_frame(lake_open(path, version = version), "path"), "zl-log-compaction", version, "add_actions")
  }
  unlink(file.path(path, "_delta_log", "00000000000000000002.json"))
  for (version in 3:5) expect_no_snapshot(lake_open(path, version = version), "zulake_error_corrupt_log")
  err <- tryCatch(lake_open(path), error = identity)
  expect_identical(err[c("file", "line")], list(file = name, line = 1L))

  path <- hand_table()
  write_commit(path, 1, add_line("part-1.parquet"))
  two <- sub("}$", paste0(",", substring(add_line("part-1.parquet"), 2L)), metadata_line())
  name <- write_json_checkpoint(path, 1, c(protocol_line(3L, 7L, "v2Checkpoint", "v2Checkpoint"), two, add_line("part-0.parquet")))
  expect_identical(lake_open(path)$files$path, c("part-0.parquet", "part-1.parquet"))
  unlink(file.path(path, "_delta_log", "00000000000000000000.json"))
  err <- tryCatch(lake_open(path), error = identity)
  expect_s3_class(err, "zulake_error_checkpoint_unreadable")
  cause <- err$parent
  while (!is.null(cause) && !inherits(cause, "zulake_error_corrupt_log")) cause <- cause$parent
  expect_identical(cause[c("file", "line")], list(file = basename(name), line = 2L))
})

# ---- compaction files hold a reconciled range (#117) ---------------------------

test_that("a compaction file with two tombstones of one path under two deletion vectors is read (#117)", {
  # Commit 1 updates f0's deletion vector, commit 2 removes it with that
  # vector and adds f1. Reconciled by (path, deletionVector.uniqueId), the
  # range 1-2 holds both tombstones of f0, as the protocol requires.
  # deltalake 1.7.0 reads the commits; zulake refused the compaction file
  # and did not fall back to them.
  dv <- list(storageType = "u", pathOrInlineDv = "vBn[lx{q8@P<9BNH/isA", offset = 1L, sizeInBytes = 36L, cardinality = 2L)
  path <- hand_table(c(protocol_line(3L, 7L, "deletionVectors", "deletionVectors"), metadata_line(), add_line("f0.parquet")))
  write_commit(path, 1, c(remove_line("f0.parquet"), add_line("f0.parquet", dv = dv)))
  write_commit(path, 2, c(remove_line("f0.parquet", dv = dv), add_line("f1.parquet")))
  commits <- lake_open(path)
  compacted <- file.path(path, "_delta_log", "00000000000000000001.00000000000000000002.compacted.json")
  writeLines(c(remove_line("f0.parquet"), remove_line("f0.parquet", dv = dv), add_line("f1.parquet")), compacted)
  # Commit 1 gone: replay needs the compaction file, and reads it.
  unlink(file.path(path, "_delta_log", "00000000000000000001.json"))
  tbl <- lake_open(path)
  expect_identical(tbl$files, commits$files)
  expect_identical(tbl$removed[c("path", "deletion_vector_id")], commits$removed[c("path", "deletion_vector_id")])
  expect_identical(tbl$removed$deletion_vector_id, c("", "uvBn[lx{q8@P<9BNH/isA@1"))
  # One logical file twice in a compaction file is still refused, and an
  # add with a remove of it; the same path with another vector is not.
  bad <- list(
    adds = c(add_line("f1.parquet"), add_line("f1.parquet")),
    removes = c(remove_line("f0.parquet", dv = dv), remove_line("f0.parquet", dv = dv), add_line("f1.parquet")),
    both = c(remove_line("f0.parquet"), add_line("f1.parquet"), remove_line("f1.parquet"))
  )
  for (case in names(bad)) {
    writeLines(bad[[case]], compacted)
    err <- tryCatch(lake_open(path), error = identity)
    expect_s3_class(err, "zulake_error_corrupt_log")
    expect_identical(err$file, basename(compacted), label = case)
  }
  writeLines(c(remove_line("f0.parquet"), add_line("f0.parquet", dv = dv), add_line("f1.parquet")), compacted)
  expect_identical(lake_open(path)$files$path, c("f0.parquet", "f1.parquet"))
})

test_that("a compaction file the action checks refuse is passed over for its commits, and refused when needed (#117)", {
  path <- local_fixture_copy("zl-log-compaction")
  name <- "00000000000000000001.00000000000000000003.compacted.json"
  f <- file.path(path, "_delta_log", name)
  lines <- readLines(f, warn = FALSE, encoding = "UTF-8")
  j <- which(startsWith(lines, "{\"add\":{"))[1L]
  checks <- list(
    two_adds = append(lines, lines[j], after = j),
    add_without_size = c(lines, "{\"add\":{\"path\":\"x.parquet\",\"partitionValues\":{}}}"),
    two_protocols = c(lines, protocol_line(), protocol_line())
  )
  for (case in names(checks)) {
    copy <- local_copy_dir(path)
    writeLines(checks[[case]], file.path(copy, "_delta_log", name), useBytes = TRUE)
    for (version in oracle_versions("zl-log-compaction")) {
      expect_oracle(replay_files_frame(lake_open(copy, version = version), "path"), "zl-log-compaction", version, "add_actions")
    }
    unlink(file.path(copy, "_delta_log", "00000000000000000002.json"))
    for (version in 3:5) expect_no_snapshot(lake_open(copy, version = version), "zulake_error_corrupt_log")
    expect_identical(tryCatch(lake_open(copy), error = identity)$file, name, label = case)
  }
})

# ---- the schema, validated at open (#120) --------------------------------------

test_that("a schema zulake cannot read as written is refused at open, naming the field (#120)", {
  cases <- list(
    "schema-unknown-type" = list("corrupt_log", "label", "type \"varchar(10)\""),
    "schema-upper-case-type" = list("corrupt_log", "label", "type \"STRING\""),
    "schema-field-without-type" = list("corrupt_log", "label", "has no type"),
    "schema-duplicate-name" = list("corrupt_log", "label", "two fields named \"label\""),
    "schema-duplicate-name-case" = list("corrupt_log", "LABEL", "\"label\" and \"LABEL\", which differ only in case"),
    "schema-duplicate-name-case-nested" = list("corrupt_log", "x.A", "\"a\" and \"A\", which differ only in case"),
    "schema-field-without-name" = list("corrupt_log", NULL, "field 3 of the schema has no name"),
    "schema-empty-name" = list("corrupt_log", NULL, "field 3 of the schema has no name"),
    "schema-variant-without-feature" = list("unsupported_feature", "label", "reader feature \"variantType\""),
    "schema-timestamp-ntz-without-feature" = list("unsupported_feature", "label", "reader feature \"timestampNtz\"")
  )
  for (name in names(cases)) {
    case <- cases[[name]]
    # deltalake 1.7.0 refuses each but the empty name, which it reads as a
    # column named "".
    refusal <- hostile_refusal(name)
    if (name == "schema-empty-name") expect_null(refusal) else expect_false(is.null(refusal), label = name)
    path <- fixture_table(name, "hostile")
    for (version in list(NULL, 0, 4)) {
      expect_no_snapshot(lake_open(path, version = version), paste0("zulake_error_", case[[1L]]))
    }
    err <- tryCatch(lake_open(path), error = identity)
    expect_identical(err$column, case[[2L]], label = name)
    expect_match(conditionMessage(err), case[[3L]], fixed = TRUE, label = name)
  }
  expect_identical(tryCatch(lake_open(fixture_table("schema-variant-without-feature", "hostile")), error = identity)$feature, "variantType")
  # deltalake 1.7.0 refuses both names that differ only in case.
  expect_match(hostile_refusal("schema-duplicate-name-case")$message, "case-insensitive", fixed = TRUE)
  expect_match(hostile_refusal("schema-duplicate-name-case-nested")$message, "case-insensitive", fixed = TRUE)
  expect_identical(tryCatch(lake_open(fixture_table("schema-timestamp-ntz-without-feature", "hostile")), error = identity)$feature, "timestampNtz")
})

test_that("two fields with one physical name in name mode are a corrupt log (#120)", {
  # Commit 0 gives `int` the physical name of `letter`; commit 2's schema
  # has its own again. deltalake 1.7.0 refuses such a schema ("Duplicate
  # `delta.columnMapping.physicalName`") and opens the last version.
  expect_null(hostile_refusal("column-mapping-duplicate-physical-name"))
  path <- fixture_table("column-mapping-duplicate-physical-name", "hostile")
  for (version in 0:1) expect_no_snapshot(lake_open(path, version = version), "zulake_error_corrupt_log")
  err <- tryCatch(lake_open(path, version = 0), error = identity)
  expect_identical(err$column, "int")
  expect_match(conditionMessage(err), "\"letter\" and \"int\"", fixed = TRUE)
  for (version in 2:3) {
    expect_oracle(replay_files_frame(lake_open(path, version = version), "path"), "column_mapping", version, "add_actions")
  }
})

test_that("nested schemas are checked at every level, and every type of the protocol opens (#120)", {
  field <- function(name, type, md = NULL) {
    f <- list(name = name, type = type, nullable = TRUE, metadata = md %||% structure(list(), names = character()))
    if (is.null(name)) f$name <- NULL
    f
  }
  meta <- function(fields, configuration = list()) {
    conf <- if (length(configuration)) configuration else structure(list(), names = character())
    json_line(list(metaData = list(
      id = "t", format = list(provider = "parquet", options = structure(list(), names = character())),
      schemaString = json_line(list(type = "struct", fields = fields)), partitionColumns = I(character()),
      configuration = conf
    )))
  }
  struct <- function(...) list(type = "struct", fields = list(...))
  open_schema <- function(fields, protocol = protocol_line(), configuration = list()) {
    path <- hand_table(c(protocol, meta(fields, configuration), add_line("a")), env = parent.frame())
    tryCatch(lake_open(path), error = identity)
  }
  ok <- list(
    field("s", "string"), field("l", "long"), field("i", "integer"), field("h", "short"), field("b", "byte"),
    field("f", "float"), field("d", "double"), field("t", "boolean"), field("y", "binary"), field("e", "date"),
    field("ts", "timestamp"), field("d1", "decimal(1,0)"), field("d38", "decimal(38,38)"), field("dsp", "decimal(5, 2)"),
    field("a", list(type = "array", elementType = "long", containsNull = TRUE)),
    field("m", list(type = "map", keyType = "string", valueType = struct(field("v", "long")), valueContainsNull = TRUE)),
    field("st", struct(field("x", "long"), field("y", "long"))),
    # PROTOCOL.md defines void, a column of nulls only (#133), at any level.
    field("v", "void"), field("sv", struct(field("x", "long"), field("nv", "void")))
  )
  expect_s3_class(open_schema(ok), "zulake_table")
  ntz <- protocol_line(3L, 7L, "timestampNtz", "timestampNtz")
  expect_s3_class(open_schema(list(field("n", struct(field("t", "timestamp_ntz")))), ntz), "zulake_table")
  corrupt <- list(
    list(field("a", list(type = "array", elementType = "varchar(3)", containsNull = TRUE)), "a.element", "varchar(3)"),
    list(field("a", list(type = "array", containsNull = TRUE)), "a", "has no element type"),
    list(field("m", list(type = "map", valueType = "long", valueContainsNull = TRUE)), "m", "has no key type"),
    list(field("m", list(type = "map", keyType = "long", valueContainsNull = TRUE)), "m", "has no value type"),
    list(field("s", struct(field("y", "long"), field("y", "long"))), "s.y", "two fields named \"y\""),
    list(field("s", struct(field(NULL, "long"))), "s", "field 1 of \"s\" has no name"),
    list(field("s", list(type = "struct")), "s", "has no fields"),
    list(field("x", list(type = "tuple")), "x", "type \"tuple\""),
    list(field("x", 3L), "x", "has no type"),
    list(field("x", "decimal"), "x", "type \"decimal\""),
    list(field("x", "decimal(39,0)"), "x", "type \"decimal(39,0)\""),
    list(field("x", "decimal(0,0)"), "x", "type \"decimal(0,0)\""),
    list(field("x", "decimal(5,6)"), "x", "type \"decimal(5,6)\""),
    list(field("ID", "long"), "ID", "\"id\" and \"ID\", which differ only in case"),
    list(field("s", struct(field("x", "long"), field("X", "long"))), "s.X", "\"x\" and \"X\", which differ only in case"),
    list(field("interval", "interval year to month"), "interval", "type \"interval year to month\""),
    list(field("x", "interval day to second"), "x", "type \"interval day to second\""),
    list(list(name = 3L, type = "long"), NULL, "field 2 of the schema has no name")
  )
  for (case in corrupt) {
    err <- open_schema(list(field("id", "long"), case[[1L]]))
    label <- case[[3L]]
    expect_s3_class(err, "zulake_error_corrupt_log")
    expect_identical(err$column, case[[2L]], label = label)
    expect_match(conditionMessage(err), case[[3L]], fixed = TRUE, label = label)
  }
  for (type in list("variant", list(type = "array", elementType = "variant", containsNull = TRUE))) {
    err <- open_schema(list(field("v", type)))
    expect_s3_class(err, "zulake_error_unsupported_feature")
    expect_identical(err$feature, "variantType")
  }
  err <- open_schema(list(field("n", struct(field("t", "timestamp_ntz")))), protocol_line(3L, 7L, character(), character()))
  expect_s3_class(err, "zulake_error_unsupported_feature")
  expect_identical(err[c("feature", "column")], list(feature = "timestampNtz", column = "n.t"))
  # Name mode: physical names unique at each level of the schema.
  cm <- list(delta.columnMapping.mode = "name")
  pn <- function(x) list(delta.columnMapping.physicalName = x)
  err <- open_schema(
    list(field("a", "long", pn("c1")), field("s", struct(field("p", "long", pn("c3")), field("q", "long", pn("c3"))), pn("c2"))),
    protocol_line(2L, 5L), cm
  )
  expect_s3_class(err, "zulake_error_corrupt_log")
  expect_identical(err$column, "s.q")
  # A physical name that is another field's logical name is legal.
  tbl <- open_schema(list(field("a", "long", pn("b")), field("b", "long", pn("a"))), protocol_line(2L, 5L), cm)
  expect_s3_class(tbl, "zulake_table")
})

test_that("names that differ only in case are folded in ASCII alone, whatever the locale (#134)", {
  fold <- zulake:::fold_case
  expect_identical(fold(c("ID", "Id", "a_B9", "\u00c9t\u00c9")), c("id", "id", "a_b9", "\u00c9t\u00c9"))
  withr::with_locale(c(LC_CTYPE = "C", LC_COLLATE = "C"), {
    expect_identical(fold("ABC"), "abc")
    expect_identical(fold("\u00c9"), "\u00c9")
  })
  # Non-ASCII names that differ only in case are not refused: an
  # under-refusal, documented (design section 4.2).
  path <- hand_table(c(protocol_line(), metadata_line(c(id = "long", "\u00e9" = "long", "\u00c9" = "long")), add_line("a")))
  expect_s3_class(lake_open(path), "zulake_table")
  # Filters and `columns` still match names as written.
  path <- hand_table(c(protocol_line(), metadata_line(c(id = "long")), add_line("a")))
  expect_error(lake_read(lake_open(path), columns = "ID"), class = "zulake_error_argument")
})

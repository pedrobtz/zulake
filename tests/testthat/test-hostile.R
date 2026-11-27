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
    float = c("one", "1,5", "1.5.5", "In", "infin", "e5"),
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
  # A type the protocol may add later is not guessed at here; reading it
  # is what refuses it.
  expect_true(zulake:::partition_value_ok("anything", "void"))
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

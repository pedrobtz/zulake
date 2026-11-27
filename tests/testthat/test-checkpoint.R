# Checkpoint rows turned into actions (R/checkpoint.R): the values zujson
# gives the same actions written as JSON, which is the oracle here.

test_that("scalars become what zujson parses from the same JSON", {
  json <- c("0", "1", "-1", "2147483647", "-2147483647", "-2147483648", "3000000000", "9007199254740991", "1.5", "-0.25")
  expected <- lapply(json, function(j) zujson::json_parse(j))
  expect_identical(zulake:::atomic_values(as.numeric(json)), expected)
  # Integers past 2^53 - 1, from qio's integer64 mode: the marked digits a
  # commit's would become (int64.R).
  skip_if_not_installed("bit64")
  big <- c("9007199254740992", "9007199254740993", "-9223372036854775807", "12", "9007199254740991")
  marked <- lapply(big, function(j) {
    zulake:::parse_marked(paste0("{\"v\":", j, "}"))$v
  })
  expect_identical(zulake:::atomic_values(bit64::as.integer64(big)), marked)
  expect_identical(zulake:::atomic_values(bit64::as.integer64(c(NA, "5"))), list(NULL, 5L))
})

test_that("null scalars are NULL, strings and logicals stay as they are", {
  expect_identical(zulake:::atomic_values(c("a", NA, "")), list("a", NULL, ""))
  expect_identical(zulake:::atomic_values(c(TRUE, NA, FALSE)), list(TRUE, NULL, FALSE))
  expect_identical(zulake:::atomic_values(c(NA_real_, 2)), list(NULL, 2L))
  expect_identical(zulake:::atomic_values(c(NA_integer_, 7L)), list(NULL, 7L))
  expect_identical(zulake:::atomic_values(numeric()), list())
})

test_that("lists and maps become what zujson parses from JSON arrays and objects", {
  map <- function(k, v) data.frame(key = k, value = v, stringsAsFactors = FALSE)
  cases <- list(
    list(NULL, NULL),
    list(character(), zujson::json_parse("[]")),
    list(c("a", "b"), zujson::json_parse("[\"a\",\"b\"]")),
    list(c("a", NA), zujson::json_parse("[\"a\",null]")),
    list(c(1, 2), zujson::json_parse("[1,2]")),
    list(map(character(), character()), zujson::json_parse("{}")),
    list(map(c("k", "j"), c("v", NA)), zujson::json_parse("{\"k\":\"v\",\"j\":null}")),
    list(map("a=b", "%2F"), zujson::json_parse("{\"a=b\":\"%2F\"}")),
    list(map(c("pa\u00eds", "k"), c("S\u00e3o Paulo", "\u65e5\u672c")), zujson::json_parse("{\"pa\u00eds\":\"S\u00e3o Paulo\",\"k\":\"\u65e5\u672c\"}"))
  )
  for (case in cases) {
    expect_identical(zulake:::nested_value(case[[1L]]), case[[2L]])
  }
  # A LIST of longs from qio's integer64 mode: what zujson parses from the
  # JSON array, numbers past 2^53 - 1 marked as in a commit (int64.R).
  skip_if_not_installed("bit64")
  longs <- list(
    "[1,2]" = c("1", "2"),
    "[3000000000,1]" = c("3000000000", "1"),
    "[9007199254740993,1]" = c("9007199254740993", "1"),
    "[9007199254740993,-9223372036854775807]" = c("9007199254740993", "-9223372036854775807"),
    "[9007199254740993,null]" = c("9007199254740993", NA),
    "[null,5]" = c(NA, "5"),
    "[]" = character()
  )
  for (json in names(longs)) {
    expected <- zulake:::parse_marked(paste0("{\"v\":", json, "}"))$v
    expect_identical(zulake:::nested_value(bit64::as.integer64(longs[[json]])), expected, label = json)
  }
})

test_that("a null struct is NULL, and a struct of nulls an object without its null fields", {
  inner <- structure(
    data.frame(storageType = c("u", NA, NA), offset = c(1L, NA, NA)),
    class = c("qio_struct", "data.frame"), null = c(FALSE, FALSE, TRUE)
  )
  outer <- structure(
    data.frame(path = c("a", "b", NA)),
    class = c("qio_struct", "data.frame"), null = c(FALSE, FALSE, TRUE)
  )
  outer$deletionVector <- inner
  expect_identical(zulake:::struct_present(outer), c(TRUE, TRUE, FALSE))
  values <- zulake:::struct_values(outer, 1:3)
  expect_identical(values[[1L]], list(path = "a", deletionVector = list(storageType = "u", offset = 1L)))
  expect_identical(values[[2L]], list(path = "b", deletionVector = structure(list(), names = character())))
  expect_null(values[[3L]])
  # A required struct (a plain data frame) is present in every row.
  expect_identical(zulake:::struct_present(data.frame(path = c("a", NA))), c(TRUE, TRUE))
})

test_that("a checkpoint's rows are its actions, in row order, without the others", {
  path <- file.path(fixture_table("zl-checkpoint"), "_delta_log", "00000000000000000010.checkpoint.parquet")
  actions <- zulake:::log_parquet_actions(zulake:::storage_local(dirname(dirname(path))), "_delta_log/00000000000000000010.checkpoint.parquet", NA)
  data <- qio::read_parquet(path)
  kinds <- vapply(actions, names, "")
  expect_identical(length(actions), nrow(data))
  expect_identical(sum(kinds == "add"), sum(!qio::is_null_struct(data$add)))
  expect_identical(sum(kinds == "remove"), sum(!qio::is_null_struct(data$remove)))
  expect_identical(sum(kinds == "protocol"), 1L)
  expect_identical(sum(kinds == "metaData"), 1L)
  # Each add equals the add of the commit that wrote it, but for dataChange,
  # which some checkpoint writers set to false.
  tbl <- lake_open(local_commits_only("zl-checkpoint"), version = 10)
  adds <- lapply(actions[kinds == "add"], `[[`, "add")
  adds <- adds[order(vapply(adds, `[[`, "", "path"), method = "radix")]
  expect_identical(lapply(adds, action_core), lapply(tbl$files$action, action_core))
})

test_that("statistics as structs are not read; partitionValues and stats are", {
  path <- fixture_table("table_failed_last_checkpoint_update")
  plan <- qio::read_plan(file.path(path, "_delta_log", "00000000000000000003.checkpoint.parquet"))
  expect_true(any(startsWith(plan$path, "add.stats_parsed.")))
  actions <- zulake:::log_parquet_actions(zulake:::storage_local(path), "_delta_log/00000000000000000003.checkpoint.parquet", NA)
  adds <- Filter(Negate(is.null), lapply(actions, `[[`, "add"))
  expect_gt(length(adds), 0L)
  for (a in adds) {
    expect_false("stats_parsed" %in% names(a))
    expect_true(zulake:::is_string(a$stats))
    expect_true(is.list(a$partitionValues))
  }
  expect_true(zulake:::parsed_field("add.stats_parsed"))
  expect_true(zulake:::parsed_field("add.partitionValues_parsed"))
  expect_false(zulake:::parsed_field("add.stats"))
  expect_false(zulake:::parsed_field("add.stats_parsed.numRecords"))
})

test_that("a 64-bit integer a double cannot hold is read again as integer64, or the checkpoint is unreadable", {
  calls <- character()
  fake <- function(file, columns, int64 = "double") {
    calls <<- c(calls, int64)
    if (int64 == "double") {
      warning("Some INT64 or UINT64 values in column 'txn.version' were coerced to NA")
      return(data.frame(x = NA_real_))
    }
    data.frame(x = bit64::as.integer64("9007199254740993"))
  }
  local_mocked_bindings(read_parquet = fake, .package = "qio")
  skip_if_not_installed("bit64")
  out <- zulake:::read_log_parquet("f.parquet", "txn.version")
  expect_identical(calls, c("double", "integer64"))
  expect_identical(zulake:::atomic_values(out$x), list(zulake:::make_marked("9007199254740993")))

  # A value integer64 cannot hold either: the warning is an error.
  local_mocked_bindings(read_parquet = function(file, columns, int64 = "double") {
    warning("Some INT64 or UINT64 values in column 'txn.version' were coerced to NA")
    data.frame(x = NA_real_)
  }, .package = "qio")
  expect_error(zulake:::read_log_parquet("f.parquet", "txn.version"), "coerced to NA")

  local_mocked_bindings(has_bit64 = function() FALSE)
  expect_error(zulake:::read_log_parquet("f.parquet", "txn.version"), "bit64", class = "zulake_checkpoint_refusal")
})

test_that("shapes no action has are refused, so the checkpoint is unreadable", {
  expect_error(zulake:::parquet_actions(data.frame(add = 1)), "not a struct")
  expect_error(zulake:::nested_value(list(list(1))), "does not read")
  expect_error(zulake:::atomic_values(as.Date("2024-01-01")), "date or time")
})

test_that("a checkpoint is read from a store without local paths, and an auth failure is not passed over", {
  path <- fixture_table("zl-checkpoint")
  local <- zulake:::storage_local(path)
  remote <- local
  remote$local_path <- NULL
  remote$kind <- "remote"
  expect_same_state(zulake:::snapshot_build(remote, path), lake_open(path), "no local paths")
  denied <- remote
  denied$get <- function(p) {
    if (grepl("[.]checkpoint[.]", p)) zulake:::zulake_abort("auth", "refused", status = 403L)
    local$get(p)
  }
  expect_no_snapshot(zulake:::snapshot_build(denied, path), "zulake_error_auth")
})

test_that("an unknown reader feature in a checkpoint is refused by name before any data file is read", {
  path <- hand_table()
  write_commit(path, 1, add_line("part-1.parquet"))
  write_json_checkpoint(path, 1, c(
    protocol_line(3L, 7L, c("v2Checkpoint", "zulakeFromCheckpoint"), "v2Checkpoint"),
    metadata_line(), add_line("part-0.parquet"), add_line("part-1.parquet")
  ))
  unlink(file.path(path, "_delta_log", "00000000000000000000.json"))
  rec <- new.env()
  storage <- recording_storage(zulake:::storage_local(path), rec)
  err <- tryCatch(zulake:::snapshot_build(storage, path), error = identity)
  expect_s3_class(err, "zulake_error_unsupported_feature")
  expect_identical(err$feature, "zulakeFromCheckpoint")
  expect_true(all(startsWith(sub("^[a-z_]+ ", "", rec$calls), "_delta_log/")))
  expect_true(any(grepl("checkpoint[.].*[.]json$", rec$calls)))
})

test_that("a sidecar path outside _delta_log/_sidecars/ makes the checkpoint unreadable", {
  path <- hand_table()
  write_commit(path, 1, add_line("part-1.parquet"))
  write_json_checkpoint(path, 1, c(
    protocol_line(3L, 7L, "v2Checkpoint", "v2Checkpoint"), metadata_line(),
    json_line(list(sidecar = list(path = "../elsewhere.parquet", sizeInBytes = 1L, modificationTime = 0L)))
  ))
  # Commit 0 is there, so replay falls back to it.
  expect_identical(lake_open(path)$files$path, c("part-0.parquet", "part-1.parquet"))
  unlink(file.path(path, "_delta_log", "00000000000000000000.json"))
  err <- tryCatch(lake_open(path), error = identity)
  expect_s3_class(err, "zulake_error_checkpoint_unreadable")
  expect_s3_class(err$parent$parent, "zulake_error_corrupt_log")
})

test_that("a checkpoint whose actions break the protocol is a corrupt log", {
  path <- hand_table()
  write_commit(path, 1, add_line("part-1.parquet"))
  write_json_checkpoint(path, 1, c(protocol_line(3L, 7L, "v2Checkpoint", "v2Checkpoint"), metadata_line(), "{\"add\":{\"size\":1}}"))
  expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
})

test_that("a Parquet checkpoint with no action column has no protocol, and is a corrupt log", {
  path <- hand_table()
  write_commit(path, 1, add_line("part-1.parquet"))
  name <- "_delta_log/00000000000000000001.checkpoint.parquet"
  qio::write_parquet(data.frame(foo = 1), file.path(path, name))
  expect_identical(zulake:::log_parquet_actions(storage_local(path), name, NA), list())
  expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
})

test_that("only read failures pass a checkpoint over, never another error (#89)", {
  path <- fixture_table("zl-checkpoint")
  want <- lake_open(path)
  # A plain error inside zulake's own checkpoint code (a bug) propagates as
  # it is, rather than being passed over for the commits.
  local({
    local_mocked_bindings(parquet_actions = function(data) stop("a bug in parquet_actions"))
    err <- tryCatch(lake_open(path), error = identity)
    expect_false(inherits(err, "zulake_error"))
    expect_identical(conditionMessage(err), "a bug in parquet_actions")
  })
  # An error of qio's while reading is a read failure: passed over for the
  # commits, and checkpoint_unreadable when they are gone.
  local({
    local_mocked_bindings(read_plan = function(...) stop("qio: cannot open the file"), .package = "qio")
    expect_same_state(lake_open(path), want, "qio read_plan fails")
  })
  local({
    local_mocked_bindings(read_parquet = function(...) stop("qio: cannot decode a column"), .package = "qio")
    expect_same_state(lake_open(path), want, "qio read_parquet fails")
  })
  copy <- local_fixture_copy("zl-checkpoint")
  unlink(file.path(copy, "_delta_log", sprintf("%020d.json", 0:9)))
  local_mocked_bindings(read_plan = function(...) stop("qio: cannot open the file"), .package = "qio")
  err <- tryCatch(lake_open(copy), error = identity)
  expect_s3_class(err, "zulake_error_checkpoint_unreadable")
  expect_match(conditionMessage(err$parent), "qio: cannot open the file", fixed = TRUE)
  # So is a value of a shape no action has, and a 64-bit integer without
  # bit64: refusals of this file's own, each classed.
  expect_error(zulake:::parquet_actions(data.frame(add = 1)), class = "zulake_checkpoint_refusal")
  expect_error(zulake:::nested_value(list(list(1))), class = "zulake_checkpoint_refusal")
  expect_error(zulake:::atomic_values(as.Date("2024-01-01")), class = "zulake_checkpoint_refusal")
})

test_that("a qio warning other than 64-bit loss is reported as itself (#71)", {
  int32 <- "Some INT32 values in column 'protocol.minReaderVersion' were coerced to NA because R's integer type reserves -2147483648 as its missing value."
  other <- "something else qio says"
  for (msg in c(int32, other)) {
    calls <- character()
    local_mocked_bindings(read_parquet = function(file, columns, int64 = "double") {
      calls <<- c(calls, int64)
      warning(msg)
      data.frame(x = NA_real_)
    }, .package = "qio")
    for (bit64 in c(TRUE, FALSE)) {
      local_mocked_bindings(has_bit64 = function() bit64)
      calls <- character()
      err <- tryCatch(zulake:::read_log_parquet("f.parquet", "protocol.minReaderVersion"), error = identity)
      expect_s3_class(err, "zulake_checkpoint_refusal")
      expect_identical(conditionMessage(err), msg)
      expect_identical(calls, "double")
    }
  }
  # The INT64 loss, in both of qio's wordings, is a re-read with integer64.
  for (msg in c(
    "Some INT64 or UINT64 values in column 'add.size' were coerced to NA because they cannot be represented exactly as R doubles; use int64 = \"integer64\" to preserve the supported 64-bit range.",
    "Some INT64 or UINT64 values in column 'add.size' were coerced to NA"
  )) {
    local_mocked_bindings(read_parquet = function(file, columns, int64 = "double") {
      if (int64 == "double") warning(msg)
      data.frame(x = 1)
    }, .package = "qio")
    local_mocked_bindings(has_bit64 = function() FALSE)
    expect_error(zulake:::read_log_parquet("f.parquet", "add.size"), "bit64", class = "zulake_checkpoint_refusal")
  }
})

test_that("a MAP that repeats a key is a refusal of the checkpoint, not a corrupt log (#108)", {
  map <- function(k, v) data.frame(key = k, value = v, stringsAsFactors = FALSE)
  for (keys in list(c("p", "q", "p"), c("p", "p"), c("pa\u00eds", "k", "pa\u00eds"))) {
    err <- tryCatch(zulake:::nested_value(map(keys, as.character(seq_along(keys)))), error = identity)
    expect_s3_class(err, "zulake_checkpoint_refusal")
    expect_false(inherits(err, "zulake_error"))
    expect_match(conditionMessage(err), sprintf("the key \"%s\" twice", keys[1L]), fixed = TRUE)
  }
  # Keys that differ only in case, or only in a null value, are distinct.
  expect_identical(names(zulake:::nested_value(map(c("p", "P"), c("1", NA)))), c("p", "P"))
})

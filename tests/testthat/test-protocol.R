# The reader-feature gate (D7): a reader feature zulake does not support is
# refused by name, before any file outside _delta_log/ is read.

test_that("columnMapping in id mode is refused by name at every version", {
  for (version in oracle_versions("column_mapping_id_mode")) {
    err <- tryCatch(lake_open(fixture_table("column_mapping_id_mode"), version = version), error = identity)
    expect_s3_class(err, "zulake_error_unsupported_feature")
    expect_s3_class(err, "zulake_error")
    expect_identical(err$feature, "columnMapping")
    expect_match(conditionMessage(err), "\"id\" mode", fixed = TRUE)
  }
  # deltalake reads it (design section 8: a deliberate difference).
  expect_null(oracle_refusal("column_mapping_id_mode", 3))
  # The same table in name mode opens.
  expect_identical(lake_open(fixture_table("column_mapping"))$column_mapping, "name")
})

test_that("catalogManaged is refused by name, as deltalake refuses it", {
  path <- fixture_table("zl-catalog-managed")
  err <- tryCatch(lake_open(path), error = identity)
  expect_s3_class(err, "zulake_error_unsupported_feature")
  expect_identical(err$feature, "catalogManaged")
  expect_identical(err$version, 1)
  expect_false(is.null(oracle_refusal("zl-catalog-managed", 1)))
  # Version 0, before the upgrade, opens and equals deltalake.
  tbl <- lake_open(path, version = 0)
  expect_oracle(replay_files_frame(tbl, "path"), "zl-catalog-managed", 0, "add_actions")
  # By timestamp the latest version decides how commits are timed, so it is
  # refused too.
  expect_error(lake_open(path, timestamp = as.POSIXct("1990-01-01", tz = "UTC")), class = "zulake_error_unsupported_feature")
})

test_that("an unknown reader feature is refused by name, as deltalake refuses it", {
  path <- fixture_table("zl-unknown-reader-feature")
  err <- tryCatch(lake_open(path), error = identity)
  expect_s3_class(err, "zulake_error_unsupported_feature")
  expect_identical(err$feature, "zulakeUnknownFeature")
  expect_match(oracle_refusal("zl-unknown-reader-feature", 1)$message, "zulakeUnknownFeature", fixed = TRUE)
  expect_oracle(replay_files_frame(lake_open(path, version = 0), "path"), "zl-unknown-reader-feature", 0, "add_actions")
})

test_that("refusals read nothing outside _delta_log/, even with the data files gone", {
  for (table in c("column_mapping_id_mode", "zl-catalog-managed", "zl-unknown-reader-feature")) {
    path <- local_fixture_copy(table)
    files <- list.files(path, recursive = TRUE, all.files = TRUE)
    data <- files[!startsWith(files, "_delta_log/")]
    expect_gt(length(data), 0L)
    unlink(file.path(path, data))

    rec <- new.env()
    storage <- recording_storage(zulake:::storage_local(path), rec)
    expect_error(zulake:::snapshot_build(storage, path), class = "zulake_error_unsupported_feature")
    expect_gt(length(rec$calls), 0L)
    paths <- sub("^[a-z_]+ ", "", rec$calls)
    expect_true(all(startsWith(paths, "_delta_log/")), label = paste(table, paste(rec$calls, collapse = "; ")))
  }
})

test_that("recording_storage() records every call it passes on", {
  path <- fixture_table("zl-basic")
  rec <- new.env()
  storage <- recording_storage(zulake:::storage_local(path), rec)
  storage$list("_delta_log/")
  data <- list.files(path, pattern = "[.]parquet$")[1L]
  storage$get(data)
  storage$head(data)
  storage$get_range(data, 0, 3)
  expect_identical(rec$calls, paste(c("list", "get", "head", "get_range"), c("_delta_log/", data, data, data)))
})

test_that("each reader feature the protocol names is supported or refused by name", {
  # The protocol's appendix "Valid Feature Names in Table Features" lists
  # these as reader (and writer) features; variantType, variantShredding and
  # typeWidening are reader features its own sections name.
  supported <- c("columnMapping", "deletionVectors", "timestampNtz", "v2Checkpoint")
  refused <- c("catalogManaged", "vacuumProtocolCheck", "variantType", "variantShredding", "typeWidening",
               "variantType-preview", "typeWidening-preview", "zulakeUnknownFeature")
  for (f in supported) {
    path <- hand_table(c(protocol_line(3L, 7L, f, f), metadata_line(), add_line("a.parquet")))
    expect_identical(lake_version(lake_open(path)), 0, label = f)
  }
  for (f in refused) {
    path <- hand_table(c(protocol_line(3L, 7L, f, f), metadata_line(), add_line("a.parquet")))
    err <- tryCatch(lake_open(path), error = identity)
    expect_s3_class(err, "zulake_error_unsupported_feature")
    expect_identical(err$feature, f, label = f)
    expect_match(conditionMessage(err), f, fixed = TRUE)
  }
  # Several unsupported features are all named.
  path <- hand_table(c(
    protocol_line(3L, 7L, c("deletionVectors", "catalogManaged", "zzz"), "deletionVectors"),
    metadata_line()
  ))
  expect_identical(tryCatch(lake_open(path), error = identity)$feature, c("catalogManaged", "zzz"))
  # Reader features only count from reader version 3.
  path <- hand_table(c(protocol_line(1L, 7L, "zzz", "zzz"), metadata_line()))
  expect_identical(lake_version(lake_open(path)), 0)
})

test_that("reader versions 1 to 3 are read, and others refused", {
  for (v in 1:3) {
    path <- hand_table(c(protocol_line(v, 7L, if (v == 3L) character()), metadata_line()))
    expect_identical(lake_version(lake_open(path)), 0)
  }
  for (v in c(0L, 4L, 99L)) {
    path <- hand_table(c(protocol_line(v, 7L), metadata_line()))
    err <- tryCatch(lake_open(path), error = identity)
    expect_s3_class(err, "zulake_error_unsupported_feature")
    expect_identical(err$feature, paste("readerVersion", v))
  }
})

test_that("column mapping mode is honoured only where the protocol supports column mapping", {
  meta <- function(mode) metadata_line(configuration = list(delta.columnMapping.mode = mode))
  # Reader version 2, or 3 with the feature: the mode counts.
  for (p in list(protocol_line(2L, 5L), protocol_line(3L, 7L, "columnMapping", "columnMapping"))) {
    expect_identical(lake_open(hand_table(c(p, meta("name"))))$column_mapping, "name")
    expect_identical(lake_open(hand_table(c(p, meta("none"))))$column_mapping, "none")
    expect_identical(lake_open(hand_table(c(p, metadata_line())))$column_mapping, "none")
    for (mode in c("id", "ID", "other")) {
      err <- tryCatch(lake_open(hand_table(c(p, meta(mode)))), error = identity)
      expect_s3_class(err, "zulake_error_unsupported_feature")
      expect_identical(err$feature, "columnMapping")
    }
  }
  # Reader version 1, or 3 without the feature: the property is ignored.
  for (p in list(protocol_line(1L, 2L), protocol_line(3L, 7L, "deletionVectors", "deletionVectors"))) {
    expect_identical(lake_open(hand_table(c(p, meta("id"))))$column_mapping, "none")
  }
})

test_that("the gate looks at the snapshot's own version", {
  path <- hand_table()
  write_commit(path, 1, protocol_line(3L, 7L, "zzz", "zzz"))
  write_commit(path, 2, protocol_line(1L, 2L))
  expect_identical(lake_version(lake_open(path, version = 0)), 0)
  expect_error(lake_open(path, version = 1), class = "zulake_error_unsupported_feature")
  expect_identical(lake_version(lake_open(path)), 2)
})

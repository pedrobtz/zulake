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
  supported <- c("columnMapping", "deletionVectors", "timestampNtz", "v2Checkpoint", "vacuumProtocolCheck")
  refused <- c("catalogManaged", "variantType", "variantShredding", "typeWidening",
               "variantType-preview", "variantShredding-preview", "typeWidening-preview", "zulakeUnknownFeature")
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
  # Reader version 1, or 3 without the reader feature (as a writer feature
  # only, too): a mode other than "none" names column mapping the protocol
  # does not declare, and is refused by name before any data is read, as
  # deltalake 1.7.0 refuses it (#58); reading by logical names would give
  # NA for every value.
  for (p in list(protocol_line(1L, 2L), protocol_line(3L, 7L, "deletionVectors", "deletionVectors"),
                 protocol_line(3L, 7L, "deletionVectors", c("deletionVectors", "columnMapping")))) {
    for (mode in c("name", "id", "other")) {
      err <- tryCatch(lake_open(hand_table(c(p, meta(mode)))), error = identity)
      expect_s3_class(err, "zulake_error_unsupported_feature")
      expect_identical(err$feature, "columnMapping")
    }
    expect_identical(lake_open(hand_table(c(p, meta("none"))))$column_mapping, "none")
    expect_identical(lake_open(hand_table(c(p, metadata_line())))$column_mapping, "none")
  }
})

test_that("a name-mode table whose protocol lacks column mapping reads no data (#58)", {
  path <- file.path(withr::local_tempdir(), "t")
  dir.create(path)
  qio::write_parquet(data.frame(`col-1` = 0:4, check.names = FALSE), file.path(path, "f.parquet"))
  write_commit(path, 0, c(protocol_line(), metadata_line(c(value = "integer"), physical = c(value = "col-1"),
                                                         configuration = list(delta.columnMapping.mode = "name")),
                          add_line("f.parquet", size = file.size(file.path(path, "f.parquet")))))
  env <- new.env()
  storage <- recording_storage(storage_local(path), env)
  expect_error(snapshot_build(storage, path), class = "zulake_error_unsupported_feature")
  expect_false(any(grepl("f[.]parquet", env$calls)))
  expect_error(lake_read(lake_open(path)), class = "zulake_error_unsupported_feature")
})

test_that("the gate looks at the snapshot's own version", {
  path <- hand_table()
  write_commit(path, 1, protocol_line(3L, 7L, "zzz", "zzz"))
  write_commit(path, 2, protocol_line(1L, 2L))
  expect_identical(lake_version(lake_open(path, version = 0)), 0)
  expect_error(lake_open(path, version = 1), class = "zulake_error_unsupported_feature")
  expect_identical(lake_version(lake_open(path)), 2)
})

test_that("vacuumProtocolCheck is accepted: readers only acknowledge it, as deltalake does", {
  path <- fixture_table("zl-vacuum-protocol-check")
  for (version in oracle_versions("zl-vacuum-protocol-check")) {
    expect_null(oracle_refusal("zl-vacuum-protocol-check", version))
    tbl <- lake_open(path, version = version)
    expect_oracle(replay_files_frame(tbl, "path"), "zl-vacuum-protocol-check", version, "add_actions")
  }
  expect_identical(oracle_field("zl-vacuum-protocol-check", 2, c("protocol", "reader_features")), "vacuumProtocolCheck")
  p <- lake_protocol(lake_open(path))
  row <- p[p$name == "vacuumProtocolCheck", ]
  expect_identical(nrow(row), 1L)
  expect_true(row$reader)
  expect_true(row$writer)
  expect_true(row$supported)
})

test_that("writerFeatures are never a reason to refuse", {
  # Every name, known to the protocol as a reader feature or not, listed only
  # as a writer feature: the table opens, and lake_protocol() marks it
  # supported (zulake does not write).
  names <- c("catalogManaged", "typeWidening", "variantType", "variantShredding", "zulakeUnknownFeature",
             "columnMapping", "invariants", "checkConstraints", "rowTracking", "inCommitTimestamp")
  for (f in names) {
    path <- hand_table(c(protocol_line(3L, 7L, character(), f), metadata_line(), add_line("a.parquet")))
    tbl <- lake_open(path)
    expect_identical(lake_version(tbl), 0, label = f)
    p <- lake_protocol(tbl)
    row <- p[p$name == f, ]
    expect_identical(c(row$reader, row$writer, row$supported), c(FALSE, TRUE, TRUE), label = f)
  }
  # Reader version 1: neither list is read.
  path <- hand_table(c(protocol_line(1L, 7L, "zzz", c("zzz", "catalogManaged")), metadata_line()))
  expect_identical(lake_version(lake_open(path)), 0)
})

test_that("the refusal's protocol field marks what it refuses unsupported, and lake_protocol() agrees", {
  cases <- list(
    list(protocol_line(3L, 7L, c("deletionVectors", "typeWidening", "zzz"), c("deletionVectors", "typeWidening")),
         metadata_line(), c("typeWidening", "zzz")),
    list(protocol_line(3L, 7L, "columnMapping", "columnMapping"),
         metadata_line(configuration = list(delta.columnMapping.mode = "id")), "columnMapping"),
    list(protocol_line(4L, 7L), metadata_line(), "readerVersion")
  )
  for (case in cases) {
    err <- tryCatch(lake_open(hand_table(case[1:2])), error = identity)
    expect_s3_class(err, "zulake_error_unsupported_feature")
    p <- err$protocol
    expect_s3_class(p, "data.frame")
    expect_identical(sort(p$name[!p$supported]), sort(case[[3]]))
  }
  # The refusal names the reason for a feature the protocol defines.
  err <- tryCatch(lake_open(hand_table(c(protocol_line(3L, 7L, "typeWidening", "typeWidening"), metadata_line()))),
                  error = identity)
  expect_match(conditionMessage(err), "widened type", fixed = TRUE)
  # A table that opens: every requirement supported, and the versions and
  # feature lists equal deltalake's.
  for (table in c("zl-types", "deletion_vectors", "column_mapping", "checkpoint-v2-table", "zl-basic")) {
    v <- max(oracle_versions(table))
    p <- lake_protocol(lake_open(fixture_table(table)))
    expect_true(all(p$supported), label = table)
    expect_oracle(p$version[p$name == "readerVersion"], table, v, c("protocol", "min_reader_version"))
    expect_oracle(p$version[p$name == "writerVersion"], table, v, c("protocol", "min_writer_version"))
    rf <- oracle_field(table, v, c("protocol", "reader_features"))
    wf <- oracle_field(table, v, c("protocol", "writer_features"))
    expect_setequal(p$name[p$reader & is.na(p$version)], as.character(rf))
    expect_setequal(p$name[p$writer & is.na(p$version)], as.character(wf))
  }
})

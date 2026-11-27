# Log replay from commit 0 (roadmap Stage 2): the snapshot the protocol
# prescribes, compared with deltalake 1.7.0's answers for every fixture.

test_that("live add actions equal deltalake's at every version of every fixture", {
  for (table in fixture_names("tables")) {
    path <- fixture_table(table)
    for (version in oracle_versions(table)) {
      if (!is.null(oracle_refusal(table, version)) || table == "column_mapping_id_mode") {
        next # refusals: test-protocol.R
      }
      tbl <- lake_open(path, version = version)
      expect_identical(lake_version(tbl), version, label = paste(table, version))
      expect_identical(tbl$format, "delta")
      answer <- oracle_field(table, version, "add_actions")
      actual <- replay_files_frame(tbl, names(answer$columns))
      expect_oracle(actual, table, version, "add_actions")
      expect_identical(nrow(actual), as.integer(answer$num_rows), label = paste(table, version))

      p <- tbl$protocol
      expect_oracle(
        list(
          min_reader_version = p[["minReaderVersion"]],
          min_writer_version = p[["minWriterVersion"]],
          reader_features = if (is.null(p[["readerFeatures"]])) NULL else sort(p[["readerFeatures"]], method = "radix"),
          writer_features = if (is.null(p[["writerFeatures"]])) NULL else sort(p[["writerFeatures"]], method = "radix")
        ),
        table, version, "protocol"
      )
      expect_identical(tbl$metadata[["id"]], oracle_field(table, version, c("metadata", "id")))
    }
  }
})

test_that("application transactions are the latest version per appId, as deltalake says", {
  for (table in c("zl-basic", "checkpoint-v2-table", "zl-checkpoint")) {
    for (version in oracle_versions(table)) {
      tbl <- lake_open(fixture_table(table), version = version)
      expected <- oracle_field(table, version, "transactions")
      actual <- lapply(expected, function(x) NULL)
      for (app in names(tbl$transactions)) actual[[app]] <- tbl$transactions[[app]][["version"]]
      expect_oracle(actual, table, version, "transactions")
    }
  }
  expect_identical(lake_open(fixture_table("zl-basic"))$transactions[["other-app"]][["version"]], 7L)
})

test_that("domain metadata keeps the latest per domain and drops removed ones", {
  # deltalake does not expose domains; the oracle is the log itself
  # (PROVENANCE.md, zl-domains): commit 1 adds zulake.test {k:1} and
  # delta.zulake, commit 2 sets zulake.test to {k:2}, commit 3 removes
  # delta.zulake.
  path <- fixture_table("zl-domains")
  config <- function(tbl) vapply(tbl$domains, function(d) d[["configuration"]], "")
  expect_length(lake_open(path, version = 0)$domains, 0L)
  expect_identical(config(lake_open(path, version = 1)), c(delta.zulake = "{}", zulake.test = "{\"k\":1}"))
  expect_identical(config(lake_open(path, version = 2)), c(delta.zulake = "{}", zulake.test = "{\"k\":2}"))
  expect_identical(config(lake_open(path, version = 3)), c(zulake.test = "{\"k\":2}"))
  expect_identical(config(lake_open(path, version = 4)), c(zulake.test = "{\"k\":2}"))
})

test_that("no logical file is both live and a tombstone", {
  for (table in fixture_names("tables")) {
    tbl <- tryCatch(lake_open(fixture_table(table)), zulake_error_unsupported_feature = function(e) NULL)
    if (is.null(tbl)) next
    live <- paste(tbl$files$path, tbl$files$deletion_vector_id)
    dead <- paste(tbl$removed$path, tbl$removed$deletion_vector_id)
    expect_length(intersect(live, dead), 0L)
  }
  # simple_table removes files: the tombstones are there.
  expect_gt(nrow(lake_open(fixture_table("simple_table"))$removed), 0L)
})

test_that("a file re-added with a new deletion vector is one live row, as deltalake says", {
  # deletion_vectors commit 2 removes (path, no vector) and adds (path, dv).
  tbl <- lake_open(fixture_table("deletion_vectors"), version = 2)
  expect_identical(nrow(tbl$files), 1L)
  expect_oracle(replay_files_frame(tbl, "deletion_vector"), "deletion_vectors", 2, "add_actions")
  expect_identical(tbl$files$deletion_vector_id, "uITfmIXOK!>U^L:if1E+a@1")
  expect_identical(tbl$removed$deletion_vector_id, "")
})

test_that("the (path, deletionVector.uniqueId) key tells two logical files of one path apart", {
  # The protocol's rule, on a copy of deletion_vectors with one more commit:
  # removing (path, no vector) again leaves (path, dv) live; removing
  # (path, dv) removes it.
  path <- local_fixture_copy("deletion_vectors")
  tbl <- lake_open(path)
  file <- tbl$files$path
  dv <- tbl$files$action[[1L]][["deletionVector"]]

  write_commit(path, 3, remove_line(file))
  tbl <- lake_open(path)
  expect_identical(tbl$files$path, file)
  expect_identical(tbl$files$deletion_vector_id, "uITfmIXOK!>U^L:if1E+a@1")

  write_commit(path, 4, remove_line(file, dv = dv))
  tbl <- lake_open(path)
  expect_identical(nrow(tbl$files), 0L)
  expect_setequal(tbl$removed$deletion_vector_id, c("", "uITfmIXOK!>U^L:if1E+a@1"))
})

test_that("the deletion vector id has the offset only when there is one", {
  expect_identical(zulake:::dv_unique_id(NULL), "")
  expect_identical(zulake:::dv_unique_id(list(storageType = "i", pathOrInlineDv = "abc")), "iabc")
  expect_identical(zulake:::dv_unique_id(list(storageType = "u", pathOrInlineDv = "abc", offset = 1L)), "uabc@1")
  expect_identical(
    zulake:::dv_unique_id(list(storageType = "p", pathOrInlineDv = "x", offset = 3000000000)),
    "px@3000000000"
  )
  # Two vectors on one path that differ only in offset are two files.
  path <- hand_table(c(
    protocol_line(3L, 7L, "deletionVectors", "deletionVectors"),
    metadata_line(),
    add_line("a.parquet", dv = list(storageType = "u", pathOrInlineDv = "abc", offset = 1L, sizeInBytes = 9L, cardinality = 1L)),
    add_line("b.parquet")
  ))
  write_commit(path, 1, c(
    remove_line("a.parquet", dv = list(storageType = "u", pathOrInlineDv = "abc", offset = 2L, sizeInBytes = 9L, cardinality = 1L))
  ))
  expect_identical(lake_open(path)$files$path, c("a.parquet", "b.parquet"))
  # Offsets past 2^53 - 1 that one double would hold as one number.
  add_big <- function(offset) {
    sprintf(paste0(
      '{"add":{"path":"a.parquet","partitionValues":{},"size":9,"modificationTime":0,"dataChange":true,',
      '"deletionVector":{"storageType":"u","pathOrInlineDv":"abc","offset":%s,"sizeInBytes":9,"cardinality":1}}}'
    ), offset)
  }
  path <- hand_table(c(protocol_line(3L, 7L, "deletionVectors", "deletionVectors"), metadata_line(),
                       add_big("9007199254740992"), add_big("9007199254740993")))
  expect_setequal(lake_open(path)$files$deletion_vector_id, c("uabc@9007199254740992", "uabc@9007199254740993"))
})

test_that("a commit that removes and re-adds one logical file leaves it live", {
  path <- hand_table()
  write_commit(path, 1, c(add_line("part-0.parquet", size = 200), remove_line("part-0.parquet")))
  tbl <- lake_open(path)
  expect_identical(tbl$files$path, "part-0.parquet")
  expect_identical(tbl$files$action[[1L]][["size"]], 200L)
  expect_identical(nrow(tbl$removed), 0L)
})

test_that("the versions found equal the _delta_log/ directory listing", {
  for (table in fixture_names("tables")) {
    path <- fixture_table(table)
    entries <- zulake:::log_entries(zulake:::storage_local(path)$list("_delta_log/"))
    found <- sort(unique(entries$version[entries$kind %in% c("commit", "checkpoint")]))
    expect_identical(found, fixture_log_versions(path), label = table)
    commits <- list.files(file.path(path, "_delta_log"), pattern = "^[0-9]{20}[.]json$")
    expect_identical(entries$name[entries$kind == "commit"], sort(commits, method = "radix"), label = table)
  }
  # simple_table's uncommitted version 5 under .tmp/ is not part of the log.
  expect_identical(lake_version(lake_open(fixture_table("simple_table"))), 4)
})

test_that("a snapshot records the whole listing, each entry by kind", {
  tbl <- lake_open(fixture_table("checkpoint-v2-table"))
  log <- tbl$log
  expect_identical(sum(log$kind == "commit"), 10L)
  expect_identical(sort(log$version[log$kind == "checkpoint"]), c(6, 8))
  expect_identical(sum(log$kind == "checksum"), 10L)
  expect_identical(sum(log$kind == "last_checkpoint"), 1L)
  expect_identical(tbl$last_checkpoint[["version"]], 8)

  log <- lake_open(fixture_table("zl-multipart-checkpoint"))$log
  cp <- log[log$kind == "checkpoint", ]
  expect_identical(cp$part, c(1, 2, 3))
  expect_identical(cp$parts, c(3, 3, 3))

  log <- lake_open(fixture_table("zl-log-compaction"))$log
  cmp <- log[log$kind == "compaction", ]
  expect_identical(c(cmp$version, cmp$end_version), c(1, 3))
})

test_that("log file names are classified exactly, and others ignored", {
  names <- c(
    "00000000000000000000.json", "00000000000000000001.checkpoint.parquet",
    "00000000000000000002.checkpoint.0000000001.0000000002.parquet",
    "00000000000000000003.checkpoint.80a083e8-7026-4e79-81be-64bd76c43a11.json",
    "00000000000000000003.checkpoint.80a083e8-7026-4e79-81be-64bd76c43a11.parquet",
    "00000000000000000004.00000000000000000006.compacted.json", "00000000000000000004.crc",
    "_last_checkpoint",
    # not log entries:
    "0000000000000000000.json", "00000000000000000000.json.tmp", ".00000000000000000000.json.crc",
    "00000000000000000000.checkpoint.json", "x00000000000000000000.json", "_last_checkpoint.tmp",
    "00000000000000000004.00000000000000000006.compacted.parquet"
  )
  listing <- zulake:::new_data_frame(list(
    name = names, size = rep(1, length(names)), modification_time = rep(Sys.time(), length(names))
  ))
  e <- zulake:::log_entries(listing)
  expect_identical(e$name, names[1:8])
  expect_identical(
    e$kind,
    c("commit", "checkpoint", "checkpoint", "checkpoint", "checkpoint", "compaction", "checksum", "last_checkpoint")
  )
  expect_identical(e$version, c(0, 1, 2, 3, 3, 4, 4, NA))
})

test_that("log versions are exact up to 2^53 - 1 and refused from 2^53", {
  entries <- function(v) {
    name <- paste0(v, ".json")
    zulake:::log_entries(zulake:::new_data_frame(list(name = name, size = 1, modification_time = Sys.time())))
  }
  expect_identical(entries("00009007199254740991")$version, 2^53 - 1)
  expect_error(entries("00009007199254740992"), class = "zulake_error_corrupt_log")
  expect_error(entries("00009007199254740993"), class = "zulake_error_corrupt_log")
  expect_error(entries("99999999999999999999"), class = "zulake_error_corrupt_log")
  # and as an argument
  path <- hand_table()
  expect_error(lake_open(path, version = 2^53 - 1), class = "zulake_error_version")
  expect_error(lake_open(path, version = 2^53), class = "zulake_error_argument")
  expect_error(lake_open(path, version = 2^53 + 2), class = "zulake_error_argument")
})

test_that("log compaction files replace the commits they cover, with the same snapshot", {
  path <- local_fixture_copy("zl-log-compaction")
  without <- local_fixture_copy("zl-log-compaction")
  unlink(file.path(without, "_delta_log", "00000000000000000001.00000000000000000003.compacted.json"))
  for (version in oracle_versions("zl-log-compaction")) {
    a <- lake_open(path, version = version)
    b <- lake_open(without, version = version)
    expect_identical(a$files[c("path", "deletion_vector_id")], b$files[c("path", "deletion_vector_id")])
    expect_identical(replay_files_frame(a, "path"), replay_files_frame(b, "path"))
    expect_oracle(replay_files_frame(a, "path"), "zl-log-compaction", version, "add_actions")
  }
  entries <- lake_open(path)$log
  plan <- zulake:::replay_plan(entries, 5)
  expect_identical(plan$from, c(0, 1, 4, 5))
  expect_identical(plan$to, c(0, 3, 4, 5))
  expect_identical(zulake:::replay_plan(entries, 2)$name, sprintf("%020d.json", 0:2))

  # Of two compactions from one version, the one reaching furthest within
  # the target version.
  names <- c(sprintf("%020d.json", 0:5), "00000000000000000001.00000000000000000002.compacted.json",
             "00000000000000000001.00000000000000000004.compacted.json",
             "00000000000000000001.00000000000000000005.compacted.json")
  synthetic <- zulake:::log_entries(zulake:::new_data_frame(list(
    name = names, size = rep(1, 9), modification_time = rep(Sys.time(), 9)
  )))
  expect_identical(zulake:::replay_plan(synthetic, 4)$to, c(0, 4))
  expect_identical(zulake:::replay_plan(synthetic, 5)$to, c(0, 5))
  expect_identical(zulake:::replay_plan(synthetic, 3)$to, c(0, 2, 3))

  # With commits 1 to 3 gone, the compaction file still answers versions 3
  # on; version 2 needs commit 1, and nothing covers it.
  unlink(file.path(path, "_delta_log", sprintf("%020d.json", 1:3)))
  for (version in 3:5) {
    expect_oracle(replay_files_frame(lake_open(path, version = version), "path"), "zl-log-compaction", version, "add_actions")
  }
  expect_no_snapshot(lake_open(path, version = 2), "zulake_error_corrupt_log")
})

test_that("replay from each checkpoint equals replay from commit 0, and both equal deltalake", {
  # Stage 2b. Classic (zl-checkpoint, simple_table_with_checkpoint,
  # table_failed_last_checkpoint_update, zl-checkpoint-no-last), multi-part
  # (zl-multipart-checkpoint), V2 in JSON with Parquet sidecars
  # (checkpoint-v2-table) and V2 under the classic name with a sidecar
  # (v2-classic-checkpoint-json).
  tables <- checkpoint_tables()
  expect_setequal(tables, c(
    "checkpoint-v2-table", "simple_table_with_checkpoint", "table_failed_last_checkpoint_update",
    "v2-classic-checkpoint-json", "zl-checkpoint", "zl-checkpoint-no-last", "zl-multipart-checkpoint"
  ))
  for (table in tables) {
    path <- fixture_table(table)
    commits <- local_commits_only(table)
    cps <- checkpoint_versions(path)
    expect_gt(length(cps), 0L)
    for (version in oracle_versions(table)) {
      label <- paste(table, version)
      from_cp <- lake_open(path, version = version)
      expect_same_state(from_cp, lake_open(commits, version = version), label)
      expect_oracle(replay_files_frame(from_cp, "path"), table, version, "add_actions")
      # The checkpoint was read, and no commit at or before it.
      cp <- cps[cps <= version]
      reads <- log_reads(path, version)
      if (length(cp)) {
        cp <- max(cp)
        expect_true(any(startsWith(reads, sprintf("%020.0f.checkpoint.", cp))), label = label)
        read_commits <- as.numeric(substr(reads[grepl("^[0-9]{20}[.]json$", reads)], 1L, 20L))
        expect_true(all(read_commits > cp | read_commits == version), label = paste(label, paste(reads, collapse = " ")))
      } else {
        expect_false(any(grepl("[.]checkpoint[.]", reads)), label = label)
      }
    }
  }
})

test_that("V2 sidecars are read from _delta_log/_sidecars/", {
  reads <- log_reads(fixture_table("checkpoint-v2-table"))
  expect_true(any(grepl("^_sidecars/00000000000000000008[.]checkpoint[.].*[.]parquet$", reads)))
  reads <- log_reads(fixture_table("v2-classic-checkpoint-json"))
  expect_true("00000000000000000001.checkpoint.parquet" %in% reads)
  expect_true(any(startsWith(reads, "_sidecars/00000000000000000001.checkpoint.")))
  # Every part of a multi-part checkpoint, in part order.
  reads <- log_reads(fixture_table("zl-multipart-checkpoint"), 4)
  expect_identical(
    reads[grepl("checkpoint[.][0-9]{10}", reads)],
    sprintf("00000000000000000004.checkpoint.%010d.0000000003.parquet", 1:3)
  )
})

test_that("a log whose commits before the checkpoint were removed gives the same snapshot", {
  for (table in checkpoint_tables()) {
    path <- local_fixture_copy(table)
    cp <- max(checkpoint_versions(path))
    log <- file.path(path, "_delta_log")
    commits <- list.files(log, pattern = "^[0-9]{20}[.]json$")
    unlink(file.path(log, commits[as.numeric(substr(commits, 1L, 20L)) < cp]))
    for (version in oracle_versions(table)[oracle_versions(table) >= cp]) {
      tbl <- lake_open(path, version = version)
      expect_same_state(tbl, lake_open(fixture_table(table), version = version), paste(table, version))
      expect_oracle(replay_files_frame(tbl, "path"), table, version, "add_actions")
    }
    # A version before the checkpoint is gone with its commits.
    if (cp > 0) {
      expect_no_snapshot(lake_open(path, version = cp - 1), "zulake_error_version")
    }
    expect_true(lake_is_table(path))
  }
})

test_that("a log of checkpoints alone opens, with no commit time", {
  path <- local_fixture_copy("zl-checkpoint")
  unlink(file.path(path, "_delta_log", sprintf("%020d.json", 0:12)))
  tbl <- lake_open(path)
  expect_identical(lake_version(tbl), 10)
  expect_identical(tbl$timestamp, as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"))
  expect_null(tbl$commit_info)
  expect_same_state(tbl, lake_open(fixture_table("zl-checkpoint"), version = 10), "zl-checkpoint 10")
  expect_identical(lake_version(lake_open(path, version = 5)), 5)
  expect_no_snapshot(lake_open(path, version = 4), "zulake_error_version")
  expect_no_snapshot(lake_open(path, version = 11), "zulake_error_version")
})

test_that("a checkpoint that cannot be read is passed over for an earlier one or the commits", {
  base <- lake_open(fixture_table("zl-checkpoint"))
  # Checkpoint 10 is not Parquet: replay starts at checkpoint 5.
  path <- local_fixture_copy("zl-checkpoint")
  writeBin(charToRaw("not parquet"), file.path(path, "_delta_log", "00000000000000000010.checkpoint.parquet"))
  expect_same_state(lake_open(path), base, "checkpoint 10 unreadable")
  reads <- log_reads(path)
  expect_true("00000000000000000005.checkpoint.parquet" %in% reads)
  expect_false("00000000000000000004.json" %in% reads)
  # Neither is: replay from commit 0.
  writeBin(charToRaw("not parquet"), file.path(path, "_delta_log", "00000000000000000005.checkpoint.parquet"))
  expect_same_state(lake_open(path), base, "both unreadable")
  expect_true("00000000000000000000.json" %in% log_reads(path))
  # And without commit 0 the log has neither commit 0 nor a readable checkpoint.
  unlink(file.path(path, "_delta_log", "00000000000000000000.json"))
  expect_no_snapshot(lake_open(path), "zulake_error_checkpoint_unreadable")
  err <- tryCatch(lake_open(path), error = identity)
  expect_s3_class(err, "zulake_error")
  expect_identical(err$checkpoint, 10)
  expect_s3_class(err$parent, "zulake_error_checkpoint_unreadable")

  # A V2 checkpoint whose sidecar is gone.
  path <- local_fixture_copy("checkpoint-v2-table")
  unlink(list.files(file.path(path, "_delta_log", "_sidecars"), pattern = "^00000000000000000008", full.names = TRUE))
  writeLines("{\"version\":6}", file.path(path, "_delta_log", "_last_checkpoint"))
  expect_same_state(lake_open(path), lake_open(fixture_table("checkpoint-v2-table")), "sidecar gone")
})

test_that("a multi-part checkpoint with a part missing is not used", {
  # No _last_checkpoint, so nothing says the parts should be there: the
  # commits are replayed instead.
  path <- local_fixture_copy("zl-multipart-checkpoint")
  unlink(file.path(path, "_delta_log", c("_last_checkpoint", "00000000000000000004.checkpoint.0000000002.0000000003.parquet")))
  for (version in 0:5) {
    tbl <- lake_open(path, version = version)
    expect_oracle(replay_files_frame(tbl, "path"), "zl-multipart-checkpoint", version, "add_actions")
  }
  expect_false(any(grepl("[.]checkpoint[.]", log_reads(path))))
  unlink(file.path(path, "_delta_log", sprintf("%020d.json", 0:3)))
  expect_no_snapshot(lake_open(path), "zulake_error_checkpoint_unreadable")
  expect_no_snapshot(lake_open(path, version = 4), "zulake_error_checkpoint_unreadable")
  # No commit at all, and the one checkpoint not whole.
  unlink(file.path(path, "_delta_log", sprintf("%020d.json", 4:5)))
  expect_no_snapshot(lake_open(path), "zulake_error_checkpoint_unreadable")
  expect_identical(tryCatch(lake_open(path), error = identity)$checkpoint, 4)
})

test_that("a log with a commit missing and no checkpoint is a corrupt log", {
  path <- local_fixture_copy("zl-basic")
  unlink(file.path(path, "_delta_log", "00000000000000000002.json"))
  expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
  expect_identical(lake_version(lake_open(path, version = 1)), 1)
  unlink(file.path(path, "_delta_log", "00000000000000000000.json"))
  expect_no_snapshot(lake_open(path, version = 1), "zulake_error_corrupt_log")
})

test_that("replay starts at the latest whole checkpoint, whatever a stale _last_checkpoint names", {
  tbl <- lake_open(fixture_table("zl-checkpoint"))
  expect_identical(tbl$last_checkpoint[["version"]], 10)
  # A stale _last_checkpoint (version 1, with a checkpoint at 3): checkpoint 3.
  path <- fixture_table("table_failed_last_checkpoint_update")
  tbl <- lake_open(path)
  expect_identical(tbl$last_checkpoint[["version"]], 1)
  expect_oracle(replay_files_frame(tbl, "path"), "table_failed_last_checkpoint_update", 3, "add_actions")
  reads <- log_reads(path)
  expect_true("00000000000000000003.checkpoint.parquet" %in% reads)
  expect_false("00000000000000000001.checkpoint.parquet" %in% reads)
  expect_identical(log_reads(path, 2)[[2L]], "00000000000000000001.checkpoint.parquet")
  # No _last_checkpoint: the listing finds the checkpoint.
  path <- fixture_table("zl-checkpoint-no-last")
  expect_null(lake_open(path)$last_checkpoint)
  expect_true("00000000000000000002.checkpoint.parquet" %in% log_reads(path))
})

test_that("a hand-written V2 checkpoint in JSON replays like the commits it stands for", {
  # Commit 0 adds a and b with a transaction and a domain; commit 1 removes
  # a and changes both. The checkpoint at 1 says the same, and commit 2
  # comes after it.
  p <- protocol_line(3L, 7L, "v2Checkpoint", c("v2Checkpoint", "domainMetadata"))
  m <- metadata_line(c(id = "long", p = "string"), partition = "p")
  txn <- function(v) json_line(list(txn = list(appId = "app", version = v, lastUpdated = 5)))
  dom <- function(k) json_line(list(domainMetadata = list(domain = "d", configuration = k, removed = FALSE)))
  commits <- list(
    c(p, m, add_line("a.parquet", list(p = "x")), add_line("b.parquet", list(p = NULL)), txn(1L), dom("1")),
    c(remove_line("a.parquet"), txn(2L), dom("2")),
    c(add_line("c.parquet", list(p = "z")))
  )
  path <- hand_table(commits[[1L]])
  write_commit(path, 1, commits[[2L]])
  write_commit(path, 2, commits[[3L]])
  full <- local_copy_dir(path)
  write_json_checkpoint(path, 1, c(
    json_line(list(checkpointMetadata = list(version = 1L))),
    p, m, txn(2L), dom("2"), remove_line("a.parquet"),
    add_line("b.parquet", list(p = NULL))
  ))
  unlink(file.path(path, "_delta_log", "00000000000000000000.json"))
  for (version in 1:2) {
    expect_same_state(lake_open(path, version = version), lake_open(full, version = version), paste("v2 json", version))
  }
  expect_identical(lake_open(path, version = 1)$files$path, "b.parquet")
  expect_identical(lake_open(path)$files$path, c("b.parquet", "c.parquet"))
  expect_identical(lake_open(path)$removed$path, "a.parquet")
})

# ---- time travel by timestamp ---------------------------------------------

test_that("set_commit_mtimes() gives each commit its commitInfo.timestamp", {
  path <- set_commit_mtimes(local_fixture_copy("zl-basic"))
  for (version in 0:4) {
    ts <- oracle_field("zl-basic", 4, "history")
    want <- ts[[which(vapply(ts, function(h) h$version, 0) == version)]]$timestamp
    expect_identical(commit_mtimes_ms(path)[[as.character(version)]], as.numeric(want))
  }
  expect_identical(
    as.numeric(answer_time("2025-08-09T14:43:13.561Z")) * 1000,
    1754750593561
  )
})

test_that("a timestamp selects the version deltalake's load_as_version() selects", {
  for (table in fixture_names("tables")) {
    path <- NULL
    for (version in oracle_versions(table)) {
      if (!is.null(oracle_refusal(table, version)) || table == "column_mapping_id_mode") next
      lookups <- oracle_field(table, version, "timestamp_lookup")
      if (!is.null(lookups$error)) next # deltalake could not open the latest version
      if (is.null(path)) path <- set_commit_mtimes(local_fixture_copy(table))
      for (l in lookups) {
        at <- answer_time(l$at)
        tbl <- lake_open(path, timestamp = at)
        expect_identical(lake_version(tbl), as.numeric(l$version), label = paste(table, l$at))
      }
    }
  }
})

test_that("with in-commit timestamps, the commit file times do not matter", {
  path <- local_fixture_copy("table_with_ict")
  log <- file.path(path, "_delta_log")
  # Every commit file dated 2000-01-01, in reverse order of version.
  files <- sort(list.files(log, pattern = "[.]json$", full.names = TRUE), decreasing = TRUE)
  for (i in seq_along(files)) {
    Sys.setFileTime(files[i], as.POSIXct("2000-01-01", tz = "UTC") + i)
  }
  for (version in oracle_versions("table_with_ict")) {
    for (l in oracle_field("table_with_ict", version, "timestamp_lookup")) {
      tbl <- lake_open(path, timestamp = answer_time(l$at))
      expect_identical(lake_version(tbl), as.numeric(l$version))
    }
  }
  tbl <- lake_open(path, version = 2)
  expect_identical(as.numeric(tbl$timestamp) * 1000, 1792197127819)

  # The same copy without them: the file times decide, and they say
  # otherwise. (The oracle here is the protocol's rule, not deltalake.)
  without <- local_fixture_copy("table_with_ict")
  f0 <- file.path(without, "_delta_log", "00000000000000000000.json")
  lines <- readLines(f0)
  lines <- sub("\"delta.enableInCommitTimestamps\":\"true\"", "\"delta.enableInCommitTimestamps\":\"false\"", lines, fixed = TRUE)
  writeLines(lines, f0)
  # Commit v dated 2000-01-01 00:00:0v, in version order this time.
  for (v in 0:3) {
    Sys.setFileTime(
      file.path(without, "_delta_log", sprintf("%020d.json", v)),
      as.POSIXct("2000-01-01", tz = "UTC") + v
    )
  }
  at <- answer_time(oracle_field("table_with_ict", 3, "timestamp_lookup")[[2L]]$at)
  expect_identical(lake_version(lake_open(without, timestamp = at)), 3)
  expect_identical(lake_version(lake_open(without, timestamp = as.POSIXct("2000-01-01 00:00:02.5", tz = "UTC"))), 2)
})

test_that("in-commit timestamps enabled part-way split the versions at the enablement", {
  # The protocol's rules ("Recommendations for Readers of Tables with
  # In-Commit Timestamps"), on zl-catalog-managed with its protocol changed
  # to plain in-commit timestamps: commit 1 enables them, at
  # delta.inCommitTimestampEnablementTimestamp.
  path <- local_fixture_copy("zl-catalog-managed")
  f1 <- file.path(path, "_delta_log", "00000000000000000001.json")
  lines <- readLines(f1)
  lines[2L] <- protocol_line(1L, 7L, writer_features = "inCommitTimestamp")
  writeLines(lines, f1)
  ict <- zujson::json_parse(lines[1L])$commitInfo$inCommitTimestamp
  enable <- as.POSIXct(ict / 1000, origin = "1970-01-01", tz = "UTC")
  # Commit 0's file time after commit 1's in-commit timestamp, and commit
  # 1's file time long before: neither may be used for the other side.
  Sys.setFileTime(file.path(path, "_delta_log", "00000000000000000000.json"), enable + 3600)
  Sys.setFileTime(f1, as.POSIXct("2001-01-01", tz = "UTC"))

  expect_identical(lake_version(lake_open(path, timestamp = enable)), 1)
  expect_identical(lake_version(lake_open(path, timestamp = enable + 7200)), 1)
  expect_identical(lake_version(lake_open(path, timestamp = enable - 0.001)), 0)
  expect_identical(lake_version(lake_open(path, timestamp = enable + 3600 + 1)), 1)
  expect_identical(lake_version(lake_open(path, timestamp = as.POSIXct("1999-01-01", tz = "UTC"))), 0)
  expect_identical(as.numeric(lake_open(path)$timestamp) * 1000, as.numeric(ict))
})

test_that("a timestamp after the last commit selects the latest version", {
  path <- set_commit_mtimes(local_fixture_copy("zl-basic"))
  expect_identical(lake_version(lake_open(path, timestamp = as.POSIXct("2100-01-01", tz = "UTC"))), 4)
})

test_that("an in-commit timestamp that is missing is a corrupt log", {
  path <- local_fixture_copy("table_with_ict")
  f <- file.path(path, "_delta_log", "00000000000000000002.json")
  lines <- readLines(f)
  lines[1L] <- sub("\"inCommitTimestamp\":[0-9]+,", "", lines[1L])
  writeLines(lines, f)
  expect_no_snapshot(lake_open(path, timestamp = Sys.time()), "zulake_error_corrupt_log")
  expect_no_snapshot(lake_open(path, version = 2), "zulake_error_corrupt_log")
  expect_identical(lake_version(lake_open(path, version = 1)), 1)
})

# ---- lake_load() -------------------------------------------------------------

test_that("lake_load() builds another snapshot of the same table", {
  path <- local_fixture_copy("zl-basic")
  tbl <- lake_open(path)
  old <- lake_load(tbl, version = 1)
  expect_identical(lake_version(old), 1)
  expect_identical(old$files, lake_open(path, version = 1)$files)
  expect_identical(lake_version(tbl), 4)

  # A commit appended after opening: the old snapshot does not change, a
  # new one sees it.
  write_commit(path, 5, c(json_line(list(commitInfo = list(timestamp = 1795690966432))), add_line("new.parquet")))
  expect_identical(lake_version(tbl), 4)
  expect_identical(lake_version(lake_load(tbl)), 5)
  expect_true("new.parquet" %in% lake_load(tbl)$files$path)
  expect_false("new.parquet" %in% tbl$files$path)

  set_commit_mtimes(path)
  at <- answer_time(oracle_field("zl-basic", 2, "timestamp_lookup")[[2L]]$at)
  expect_identical(lake_version(lake_load(tbl, timestamp = at)), 2)
})

test_that("the snapshot is the same in a hostile session and under a non-ASCII path", {
  base <- lake_open(fixture_table("zl-partitioned"), version = 1)
  withr::local_envvar(LC_ALL = "C")
  withr::local_options(OutDec = ",", scipen = -5, digits = 3)
  withr::local_collate("C")
  # The variable alone does not change the running session's locale (#50).
  hostile <- withr::with_locale(c(LC_CTYPE = "C"), lake_open(fixture_table("zl-partitioned"), version = 1))
  expect_identical(hostile$files, base$files)
  expect_identical(hostile$version, base$version)

  dir <- file.path(withr::local_tempdir(), "café 表")
  dir.create(dir)
  file.copy(fixture_table("zl-partitioned"), dir, recursive = TRUE, copy.date = TRUE)
  moved <- lake_open(file.path(dir, "zl-partitioned"), version = 1)
  expect_identical(moved$files, base$files)
})

test_that("a whole-millisecond file time read up to 1 us low (Windows' file.info()) keeps its millisecond", {
  # R on Windows computes (double) ticks / 1e7 - 11644473600, whose double
  # spacing near 1.8e9 s leaves a whole-millisecond time up to ~0.95 us low.
  for (ts in c(1795690965401, 1754751126036)) {
    for (low in c(0, 2e-7, 9.5e-7)) {
      x <- as.POSIXct(ts / 1000 - low, origin = "1970-01-01", tz = "UTC")
      expect_identical(mtime_ms(x), ts, label = paste(format_number(ts), low))
    }
    # Truncation is kept: 0.4015 ms past the millisecond is still in it.
    expect_identical(mtime_ms(as.POSIXct((ts + 0.4015) / 1000, origin = "1970-01-01", tz = "UTC")), ts)
    expect_identical(mtime_ms(as.POSIXct((ts + 0.98) / 1000, origin = "1970-01-01", tz = "UTC")), ts)
  }
})

test_that("a file key past R's 10000-byte limit on names replays like any other (#50)", {
  # The key is the path, a 0x1f and the deletion vector's id ("" here):
  # paths of 9998, 9999 and 10000 bytes make keys of 9999, 10000 and 10001.
  for (n in c(9998L, 9999L, 10000L)) {
    long <- paste0(strrep("d/", (n - 9L) %/% 2L), if ((n - 9L) %% 2L) "e", "f.parquet")
    expect_identical(nchar(long, "bytes"), n)
    path <- hand_table(c(protocol_line(), metadata_line(), add_line(long), add_line("short.parquet")))
    write_commit(path, 1, remove_line(long))
    expect_identical(lake_files(lake_open(path, version = 0))$path, sort(c(long, "short.parquet"), method = "radix"),
                     label = n)
    expect_identical(lake_files(lake_open(path))$path, "short.parquet", label = n)
    expect_identical(lake_removed(lake_open(path))$path, long, label = n)
  }
})

test_that("an inline deletion vector longer than 10000 characters opens and reads, as deltalake opens it (#50)", {
  skip_if_not_installed("zuroar")
  rows <- seq(0, 8198, by = 2)
  dv <- inline_dv(dv_bytes(rows), length(rows))
  expect_gt(nchar(dv$pathOrInlineDv), 10000L)
  tbl <- lake_open(dv_table(dv, n = 8200L))
  expect_identical(lake_count(tbl), 8200 - length(rows))
  expect_identical(lake_read(tbl)$id, setdiff(0:8199, rows) + 0)
})

test_that("non-ASCII paths stay distinct in a session whose encoding is not UTF-8 (#50)", {
  withr::local_locale(c(LC_CTYPE = "C"))
  e <- "g=é/a.parquet"
  escaped <- "g=<U+00E9>/a.parquet"
  path <- hand_table(c(protocol_line(), metadata_line(), add_line(e), add_line(escaped)))
  write_commit(path, 1, remove_line(escaped))
  expect_no_warning(v0 <- lake_files(lake_open(path, version = 0))$path)
  expect_identical(sort(enc2utf8(v0), method = "radix"), sort(c(enc2utf8(e), escaped), method = "radix"))
  expect_no_warning(v1 <- lake_files(lake_open(path))$path)
  expect_identical(enc2utf8(v1), enc2utf8(e))
})

test_that("timestamp travel on a log of checkpoints alone is a classed error, without a warning (#51)", {
  path <- local_fixture_copy("zl-checkpoint")
  log <- file.path(path, "_delta_log")
  unlink(list.files(log, pattern = "^[0-9]{20}[.]json$", full.names = TRUE))
  expect_identical(lake_version(lake_open(path)), 10)
  for (at in list(Sys.time(), as.POSIXct("1970-01-01", tz = "UTC"), as.POSIXct("2100-01-01", tz = "UTC"))) {
    expect_no_warning(expect_error(lake_open(path, timestamp = at), class = "zulake_error_version"))
  }
  expect_identical(nrow(lake_versions(lake_open(path))), 0L)
})

test_that("file-time commit times are made increasing before a lookup, as deltalake makes them (#52)", {
  # The oracle: zl-file-times, whose commit 1 is dated before commit 0.
  path <- set_commit_mtimes(local_fixture_copy("zl-file-times"))
  ms <- commit_mtimes_ms(path)
  expect_lt(ms[["1"]], ms[["0"]])
  for (version in oracle_versions("zl-file-times")) {
    for (l in oracle_field("zl-file-times", version, "timestamp_lookup")) {
      expect_identical(lake_version(lake_open(path, timestamp = answer_time(l$at))), as.numeric(l$version),
                       label = l$at)
    }
  }
  # Commit 1 is dated 1 ms after commit 0, everywhere a commit time is
  # given, and each time opens its own version.
  tbl <- lake_open(path)
  v <- lake_versions(tbl)
  want <- c(ms[["0"]], ms[["0"]] + 1, ms[["2"]])
  expect_identical(round(as.numeric(v$timestamp) * 1000), want)
  expect_identical(lake_history(tbl)$timestamp, rev(v$timestamp))
  expect_identical(lake_history(tbl, limit = 2)$timestamp, rev(v$timestamp)[1:2])
  expect_identical(lake_open(path, version = 1)$timestamp, v$timestamp[2L])
  expect_identical(lake_summary(lake_open(path, version = 1))$timestamp, v$timestamp[2L])
  for (i in seq_len(nrow(v))) {
    expect_identical(lake_version(lake_open(path, timestamp = v$timestamp[i])), v$version[i])
  }
  # A hand-built log: B + 100 s, B + 50 s, B + 200 s; at B + 75 s, version 0.
  hand <- hand_table(c(protocol_line(), metadata_line(), add_line("0.parquet")))
  write_commit(hand, 1, add_line("1.parquet"))
  write_commit(hand, 2, add_line("2.parquet"))
  B <- 1.7e9
  for (v in 0:2) {
    Sys.setFileTime(file.path(hand, "_delta_log", sprintf("%020d.json", v)), as.POSIXct(B + c(100, 50, 200)[v + 1] + 5e-4, tz = "UTC"))
  }
  expect_identical(lake_version(lake_open(hand, timestamp = as.POSIXct(B + 75, tz = "UTC"))), 0)
  expect_identical(lake_version(lake_open(hand, timestamp = as.POSIXct(B + 100.0005, tz = "UTC"))), 0)
  expect_identical(lake_version(lake_open(hand, timestamp = as.POSIXct(B + 100.0015, tz = "UTC"))), 1)
})

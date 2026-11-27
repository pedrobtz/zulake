# The inspection functions against deltalake 1.7.0's answers (tools/oracle),
# the oracle's own parse of each commit, and the fixtures' directories.

test_that("inspect_cases() covers every fixture deltalake and zulake both open", {
  cases <- inspect_cases()
  tables <- unique(vapply(cases, `[[`, "", "table"))
  expect_true(all(c("zl-basic", "zl-partitioned", "simple_table", "table-with-dv-small", "deletion_vectors",
                    "column_mapping", "table_with_ict", "zl-domains", "zl-vacuum-protocol-check") %in% tables))
  expect_false("column_mapping_id_mode" %in% tables)
  expect_gt(length(cases), 60L)
})

test_that("lake_files() equals deltalake's add actions at every version", {
  for (case in inspect_cases()) {
    tbl <- case_snapshot(case)
    files <- lake_files(tbl, stats = FALSE)
    aa <- oracle_field(case$table, case$version, "add_actions")
    label <- paste(case$table, case$version)
    actual <- files[c("path", "size_bytes")]
    actual$modification_time <- round(as.numeric(files$modification_time) * 1000)
    if (!is.null(aa$columns$deletion_vector)) actual$deletion_vector <- I(files$deletion_vector)
    if (!is.null(aa$columns$partition)) actual$partition <- I(files$partition)
    expect_oracle(actual, case$table, case$version, "add_actions")
    expect_identical(files$path, sort(files$path, method = "radix"), label = label)
    # Where each file is: on disk at `uri`.
    expect_true(all(file.exists(files$uri)), label = label)
    # `action` is the add action as the log holds it.
    expect_identical(files$action, tbl$files$action, label = label)
  }
})

test_that("lake_files() statistics equal deltalake's, by logical name", {
  # zl-types holds -2^63, which neither a double nor an integer64 holds:
  # test-types.R covers it.
  for (case in inspect_cases()) {
    if (case$table == "zl-types") next
    tbl <- case_snapshot(case)
    files <- lake_files(tbl)
    aa <- oracle_field(case$table, case$version, "add_actions")
    ord <- order(unlist(aa$columns$path), method = "radix")
    map <- physical_to_logical(case$table, case$version)
    expect_oracle(files["num_records"], case$table, case$version, "add_actions")
    for (col in c("min", "max", "null_count")) {
      expected <- lapply(aa$columns[[col]][ord], function(x) strip_nulls(rename_keys(x, map)))
      actual <- lapply(files[[col]], strip_nulls)
      expect_identical(lapply(actual, oracle_canon), lapply(expected, oracle_canon),
                       label = paste(case$table, case$version, col))
    }
  }
})

test_that("lake_files() parses only when asked, and has the documented columns", {
  tbl <- case_snapshot(list(table = "zl-partitioned", version = 2))
  expect_named(lake_files(tbl), c("path", "uri", "size_bytes", "modification_time", "data_change", "partition",
                                  "deletion_vector", "num_records", "null_count", "min", "max", "action"))
  expect_named(lake_files(tbl, stats = FALSE), c("path", "uri", "size_bytes", "modification_time", "data_change",
                                                 "partition", "deletion_vector", "action"))
  expect_s3_class(lake_files(tbl)$modification_time, "POSIXct")
  expect_identical(attr(lake_files(tbl)$modification_time, "tzone"), "UTC")
  for (bad in list(NA, "yes", c(TRUE, FALSE), 1)) {
    expect_error(lake_files(tbl, stats = bad), class = "zulake_error_argument")
  }
  for (bad in list(NA_character_, "int64", 1, character())) {
    expect_error(lake_files(tbl, int64 = bad), class = "zulake_error_argument")
  }
  expect_error(lake_files(list()), class = "zulake_error_argument")
})

test_that("lake_count() equals deltalake's count where every file has numRecords, and is NA otherwise", {
  for (case in inspect_cases()) {
    tbl <- case_snapshot(case)
    nr <- oracle_field(case$table, case$version, c("add_actions", "columns", "num_records"))
    missing <- sum(answer_is_null(nr))
    label <- paste(case$table, case$version)
    if (missing == 0) {
      expect_oracle(expect_silent(lake_count(tbl)), case$table, case$version, "count")
    } else {
      w <- NULL
      n <- withCallingHandlers(lake_count(tbl), zulake_warning_count_unknown = function(cnd) {
        w <<- cnd
        invokeRestart("muffleWarning")
      })
      expect_identical(n, NA_real_, label = label)
      expect_s3_class(w, "zulake_warning")
      expect_identical(w$files, missing, label = label)
      expect_identical(lake_summary(tbl)$files_without_records, missing, label = label)
    }
  }
})

test_that("lake_count() is not deltalake's 0 on simple_table at version 0, which has 5 rows", {
  # deltalake 1.7.0 sums the numRecords it has, so a table without
  # statistics counts 0; zulake never returns a partial sum (design §5).
  expect_identical(oracle_field("simple_table", 0, "count"), 0L)
  expect_identical(oracle_field("simple_table", 0, c("read", "num_rows")), 5L)
  tbl <- case_snapshot(list(table = "simple_table", version = 0))
  expect_warning(n <- lake_count(tbl), class = "zulake_warning_count_unknown")
  expect_identical(n, NA_real_)
})

test_that("lake_count() subtracts deletion vectors' cardinality, and refuses a vector without numRecords", {
  for (table in c("table-with-dv-small", "table-with-dv-small-inline", "deletion_vectors")) {
    v <- max(oracle_versions(table))
    tbl <- lake_open(fixture_table(table))
    expect_oracle(lake_count(tbl), table, v, "count")
    expect_oracle(lake_count(tbl), table, v, c("read", "num_rows"))
    expect_gt(lake_summary(tbl)$deleted_rows, 0)
  }
  dv <- list(storageType = "u", pathOrInlineDv = "vBn[lx{q8@P<9BNH/isA", offset = 1L, sizeInBytes = 36L, cardinality = 2L)
  path <- hand_table(c(protocol_line(3L, 7L, "deletionVectors", "deletionVectors"), metadata_line(),
                       add_line("a.parquet", dv = dv)))
  tbl <- lake_open(path)
  expect_error(lake_count(tbl), class = "zulake_error_corrupt_log")
  expect_error(lake_summary(tbl), class = "zulake_error_corrupt_log")
})

test_that("lake_summary() totals the live files", {
  for (case in inspect_cases()) {
    tbl <- case_snapshot(case)
    s <- lake_summary(tbl)
    aa <- oracle_field(case$table, case$version, "add_actions")
    expect_identical(nrow(s), 1L)
    expect_identical(s$files, aa$num_rows)
    expect_identical(s$bytes, sum(as.numeric(unlist(aa$columns$size_bytes))))
    expect_identical(s$version, case$version)
    expect_identical(s$files_with_deletion_vectors,
                     sum(!answer_is_null(aa$columns$deletion_vector)))
    if (!s$files_without_records) expect_oracle(s$records, case$table, case$version, "count")
  }
  # Records unknown (design section 5), in either int64 mode.
  tbl <- lake_open(fixture_table("simple_table"))
  expect_identical(lake_summary(tbl)$records, NA_real_)
  skip_if_not_installed("bit64")
  records <- lake_summary(tbl, int64 = "integer64")$records
  expect_true(bit64::is.integer64(records) && is.na(records))
})

test_that("lake_partitions() equals deltalake's partitions", {
  for (case in inspect_cases()) {
    tbl <- case_snapshot(case)
    p <- lake_partitions(tbl)
    expected <- oracle_field(case$table, case$version, "partitions")
    label <- paste(case$table, case$version)
    actual <- lapply(seq_len(nrow(p)), function(i) as.list(p[i, , drop = FALSE]))
    key <- function(x) vapply(x, function(r) paste(unlist(oracle_canon(r)), collapse = "\x1f"), "")
    act <- lapply(actual, oracle_canon)
    exp <- lapply(expected, oracle_canon)
    expect_identical(act[order(key(actual))], exp[order(key(expected))], label = label)
    expect_false(anyDuplicated(key(actual)) > 0, label = label)
    expect_identical(names(p), lake_partition_columns(tbl), label = label)
  }
})

test_that("lake_history() equals deltalake's history, and limit cuts it", {
  for (case in inspect_cases()) {
    tbl <- case_snapshot(case)
    h <- lake_history(tbl)
    # deltalake cannot answer for a version before an upgrade it refuses.
    if (!is.null(oracle_field(case$table, case$version, "history")$error)) next
    actual <- lapply(seq_len(nrow(h)), function(i) c(h$commit_info[[i]], list(version = h$version[i])))
    expect_oracle(actual, case$table, case$version, "history")
    expect_identical(h$version, sort(h$version, decreasing = TRUE))
    expect_identical(h$operation, vapply(h$commit_info, function(x) x$operation %||% NA_character_, ""))
  }
  tbl <- lake_open(fixture_table("zl-basic"))
  expect_identical(lake_history(tbl, limit = 2)$version, c(4, 3))
  expect_identical(nrow(lake_history(tbl, limit = 0)), 0L)
  expect_identical(nrow(lake_history(tbl, limit = 100)), 5L)
  # The table's 5 commits straddled.
  expect_identical(lake_history(tbl, limit = 4)$version, c(4, 3, 2, 1))
  expect_identical(lake_history(tbl, limit = 5)$version, c(4, 3, 2, 1, 0))
  expect_identical(lake_history(tbl, limit = 6)$version, c(4, 3, 2, 1, 0))
  for (bad in list(-1, 1.5, NA, "2", c(1, 2))) {
    expect_error(lake_history(tbl, limit = bad), class = "zulake_error_argument")
  }
})

test_that("lake_versions() and lake_history() time each commit as deltalake's timestamp lookup does", {
  for (table in c("zl-basic", "simple_table", "table_with_ict", "zl-partitioned")) {
    # The in-commit timestamp table keeps the unpacked files' times, which
    # differ from its commits' timestamps: only the in-commit timestamps
    # can agree with deltalake.
    path <- local_fixture_copy(table)
    if (table != "table_with_ict") set_commit_mtimes(path)
    tbl <- lake_open(path)
    v <- lake_versions(tbl)
    expect_identical(v$version, as.numeric(oracle_versions(table)))
    for (i in seq_len(nrow(v))) {
      at <- oracle_field(table, v$version[i], "timestamp_lookup")[[2L]]
      expect_identical(at$version, as.integer(v$version[i]))
      expect_identical(v$timestamp[i], answer_time(at$at), label = paste(table, v$version[i]))
    }
    h <- lake_history(tbl)
    expect_identical(h$timestamp, rev(v$timestamp))
    expect_identical(attr(v$timestamp, "tzone"), "UTC")
  }
  # An older snapshot lists only its own versions.
  expect_identical(lake_versions(lake_open(fixture_table("zl-basic"), version = 2))$version, c(0, 1, 2))
})

test_that("lake_schema() equals deltalake's schema", {
  for (case in inspect_cases()) {
    tbl <- case_snapshot(case)
    s <- lake_schema(tbl)
    actual <- lapply(seq_len(nrow(s)), function(i) list(
      name = s$name[i],
      type = if (is.null(s$type_detail[[i]])) s$type[i] else s$type_detail[[i]],
      nullable = s$nullable[i],
      metadata = s$metadata[[i]]
    ))
    expect_oracle(actual, case$table, case$version, c("schema", "fields"))
    expect_identical(s$partition, s$name %in% lake_partition_columns(tbl))
  }
  s <- lake_schema(lake_open(fixture_table("column_mapping")))
  expect_true(all(startsWith(s$physical_name, "col-")))
  s <- lake_schema(lake_open(fixture_table("zl-types")))
  expect_identical(s$type[s$name == "ntz"], "timestamp_ntz")
  expect_identical(s$type[s$name %in% c("st", "li", "mp")], c("struct", "array", "map"))
  expect_true(all(is.na(s$physical_name)))
})

test_that("lake_metadata(), lake_partition_columns() and lake_properties() equal deltalake's metadata", {
  for (case in inspect_cases()) {
    tbl <- case_snapshot(case)
    m <- lake_metadata(tbl)
    expect_identical(nrow(m), 1L)
    expect_oracle(m$id, case$table, case$version, c("metadata", "id"))
    expect_oracle(m$name, case$table, case$version, c("metadata", "name"))
    expect_oracle(m$description, case$table, case$version, c("metadata", "description"))
    expect_oracle(round(as.numeric(m$created_time) * 1000), case$table, case$version, c("metadata", "created_time"))
    expect_identical(lake_partition_columns(tbl),
                     as.character(oracle_field(case$table, case$version, c("metadata", "partition_columns"))))
    expect_identical(m$partition_columns[[1L]], lake_partition_columns(tbl))
    p <- lake_properties(tbl)
    conf <- oracle_field(case$table, case$version, c("metadata", "configuration"))
    set <- p[!p$default, ]
    expect_oracle(as.list(stats::setNames(set$value, set$key)), case$table, case$version, c("metadata", "configuration"))
    expect_false(any(p$key[p$default] %in% names(conf)))
    expect_identical(p$key, sort(p$key, method = "radix"))
  }
  p <- lake_properties(lake_open(fixture_table("zl-basic")))
  expect_identical(p$value[p$key == "delta.checkpoint.writeStatsAsJson"], "true")
  expect_true(p$default[p$key == "delta.appendOnly"])
  p <- lake_properties(lake_open(fixture_table("column_mapping")))
  expect_identical(p$value[p$key == "delta.columnMapping.mode"], "name")
  expect_false(p$default[p$key == "delta.columnMapping.mode"])
})

test_that("a metaData without format options, configuration or field metadata gives empty objects", {
  lines <- c(
    '{"protocol":{"minReaderVersion":1,"minWriterVersion":2}}',
    paste0('{"metaData":{"id":"t","format":{"provider":"parquet"},',
           '"schemaString":"{\\"type\\":\\"struct\\",\\"fields\\":[{\\"name\\":\\"id\\",\\"type\\":\\"long\\",\\"nullable\\":true}]}",',
           '"partitionColumns":[]}}')
  )
  tbl <- lake_open(raw_table(lines))
  empty <- zujson::json_parse("{}")
  m <- lake_metadata(tbl)
  expect_identical(m$format_provider, "parquet")
  expect_identical(m$format_options[[1L]], empty)
  expect_identical(m$configuration[[1L]], empty)
  expect_identical(lake_schema(tbl)$metadata[[1L]], empty)
  expect_identical(nrow(lake_properties(tbl)[!lake_properties(tbl)$default, ]), 0L)
})

test_that("lake_transactions() equals deltalake's transaction versions", {
  for (case in inspect_cases()) {
    tx <- lake_transactions(case_snapshot(case))
    expected <- strip_nulls(oracle_field(case$table, case$version, "transactions"))
    expect_identical(oracle_canon(as.list(stats::setNames(tx$version, tx$app_id))),
                     oracle_canon(expected %||% structure(list(), names = character())),
                     label = paste(case$table, case$version))
  }
  tx <- lake_transactions(lake_open(fixture_table("zl-basic")))
  expect_identical(tx$app_id, c("other-app", "zulake-app"))
  expect_s3_class(tx$last_updated, "POSIXct")
})

test_that("lake_actions() equals the oracle's own parse of each commit", {
  for (case in inspect_cases()) {
    tbl <- case_snapshot(case)
    a <- lake_actions(tbl, case$version)
    actual <- lapply(seq_len(nrow(a)), function(i) stats::setNames(list(a$action[[i]]), a$type[i]))
    expect_oracle(actual, case$table, case$version, "actions")
    expect_true(all(a$version == case$version))
    expect_identical(a$line, seq_len(nrow(a)))
  }
  tbl <- lake_open(fixture_table("zl-basic"), version = 1)
  # The log's commits after the snapshot are in the log too.
  expect_oracle(lapply(seq_len(nrow(lake_actions(tbl, 3))), function(i) {
    x <- lake_actions(tbl, 3)
    stats::setNames(list(x$action[[i]]), x$type[i])
  }), "zl-basic", 3, "actions")
  expect_error(lake_actions(tbl, 99), class = "zulake_error_version")
  for (bad in list(NULL, -1, 1.5, NA, "1", c(1, 2))) {
    expect_error(lake_actions(tbl, bad), class = "zulake_error")
  }
  expect_error(lake_actions(tbl), class = "zulake_error_argument")
})

test_that("lake_changes() is the difference of deltalake's file lists at the two versions", {
  tables <- unique(vapply(inspect_cases(), `[[`, "", "table"))
  for (table in tables) {
    versions <- vapply(Filter(function(x) x$table == table, inspect_cases()), `[[`, 0, "version")
    pairs <- c(lapply(versions[-1L], function(v) c(v - 1, v)), list(c(min(versions), max(versions)),
                                                                     c(max(versions), max(versions))))
    tbl <- lake_open(fixture_table(table), version = max(versions))
    for (pair in pairs) {
      if (!all(pair %in% versions)) next
      ch <- lake_changes(tbl, from = pair[1L], to = pair[2L])
      ka <- oracle_file_keys(table, pair[1L])
      kb <- oracle_file_keys(table, pair[2L])
      key <- paste0(ch$path, "\x1f", vapply(ch$deletion_vector, function(d) {
        if (is.null(d)) "" else paste0(d$storageType, d$pathOrInlineDv, if (!is.null(d$offset)) paste0("@", d$offset))
      }, ""))
      label <- paste(table, pair[1L], pair[2L])
      expect_setequal(key[ch$change == "added"], setdiff(kb, ka))
      expect_setequal(key[ch$change == "removed"], setdiff(ka, kb))
      expect_false(anyDuplicated(key) > 0, label = label)
    }
  }
  tbl <- lake_open(fixture_table("zl-basic"))
  expect_identical(nrow(lake_changes(tbl, from = 4)), 0L)
  expect_named(lake_changes(tbl, from = 0), c("change", names(lake_files(tbl, stats = FALSE))))
  expect_error(lake_changes(tbl, from = 3, to = 2), class = "zulake_error_argument")
  expect_error(lake_changes(tbl), class = "zulake_error_argument")
  expect_error(lake_changes(tbl, from = 0, to = 99), class = "zulake_error_version")
  # A file given a new deletion vector is removed and added.
  ch <- lake_changes(lake_open(fixture_table("deletion_vectors")), from = 1, to = 2)
  expect_identical(sort(ch$change), c("added", "removed"))
  expect_identical(ch$path[1L], ch$path[2L])
})

test_that("lake_removed() and lake_domains() equal the oracle's own parse of the commits", {
  for (case in inspect_cases()) {
    tbl <- case_snapshot(case)
    log <- oracle_replay_log(case$table, case$version)
    r <- lake_removed(tbl)
    label <- paste(case$table, case$version)
    expected <- log$removes[order(names(log$removes) %||% character(), method = "radix")]
    expect_identical(r$path, unname(vapply(expected, `[[`, "", "path")), label = label)
    expect_identical(
      round(as.numeric(r$deletion_timestamp) * 1000),
      unname(vapply(expected, function(x) as.numeric(x$deletionTimestamp %||% NA), 0)),
      label = label
    )
    expect_identical(lapply(r$action, oracle_canon), unname(lapply(expected, oracle_canon)), label = label)
    d <- lake_domains(tbl)
    expected <- log$domains[order(names(log$domains) %||% character(), method = "radix")]
    expect_identical(d$domain, names(expected) %||% character(), label = label)
    expect_identical(d$configuration, unname(unlist(expected)) %||% character(), label = label)
  }
  expect_identical(lake_domains(lake_open(fixture_table("zl-domains"), version = 2))$domain,
                   c("delta.zulake", "zulake.test"))
  expect_gt(nrow(lake_removed(lake_open(fixture_table("simple_table")))), 0L)
})

test_that("lake_log() and lake_checkpoints() equal the fixture's _delta_log/ directory", {
  for (table in fixture_names("tables")) {
    tbl <- tryCatch(lake_open(fixture_table(table), version = 0), zulake_error = function(e) NULL)
    if (is.null(tbl)) next
    dir <- file.path(fixture_table(table), "_delta_log")
    files <- list.files(dir, all.files = TRUE, no.. = TRUE)
    files <- files[!dir.exists(file.path(dir, files))]
    log_re <- "^([0-9]{20}[.](json|crc|checkpoint[.].*(parquet|json))|[0-9]{20}[.][0-9]{20}[.]compacted[.]json|_last_checkpoint)$"
    expected <- sort(files[grepl(log_re, files)], method = "radix")
    l <- lake_log(tbl)
    expect_identical(l$name, expected, label = table)
    expect_identical(l$size, as.numeric(file.size(file.path(dir, l$name))), label = table)
    cp <- lake_checkpoints(tbl)
    cp_files <- expected[grepl("[.]checkpoint[.]", expected)]
    expect_setequal(cp$name, cp_files)
    expect_identical(cp$version, as.numeric(substr(cp$name, 1L, 20L)))
    last <- file.path(dir, "_last_checkpoint")
    if (file.exists(last)) {
      v <- zujson::json_parse_file(last)$version
      expect_identical(cp$last_checkpoint, cp$version == v, label = table)
    } else {
      expect_false(any(cp$last_checkpoint))
    }
  }
  cp <- lake_checkpoints(lake_open(fixture_table("zl-multipart-checkpoint"), version = 0))
  expect_identical(unique(cp$type), "multi-part")
  expect_identical(cp$parts, c(3, 3, 3))
  cp <- lake_checkpoints(lake_open(fixture_table("checkpoint-v2-table"), version = 0))
  expect_true("v2" %in% cp$type)
  cp <- lake_checkpoints(lake_open(fixture_table("simple_table_with_checkpoint"), version = 0))
  expect_identical(cp$type, "classic")
  expect_true(cp$last_checkpoint)
})

test_that("print() summarises a snapshot and shows no credentials", {
  token <- "SECRET-TOKEN-6c1f"
  tbl <- lake_open(fixture_table("zl-basic"), credentials = function() token)
  out <- capture.output(print(tbl))
  expect_identical(out[1L], "<zulake_table> delta table, version 4")
  expect_true(any(grepl(fixture_table("zl-basic"), out, fixed = TRUE)))
  expect_true(any(grepl("files: +2 \\(2113 bytes\\)", out)))
  expect_true(any(grepl("records: +3$", out)))
  expect_false(any(grepl(token, out, fixed = TRUE)))
  expect_false(any(grepl("function", out, fixed = TRUE)))
  capture.output(res <- print(tbl))
  expect_identical(res, tbl)
  out <- capture.output(print(lake_open(fixture_table("simple_table"))))
  expect_true(any(grepl("records: +unknown \\(5 files without numRecords\\)", out)))
  # Statistics lake_files() refuses as a corrupt log: print still works.
  tbl <- lake_open(raw_table(c(raw_header(), raw_add("a.parquet", stats = "not json"))))
  expect_error(lake_files(tbl), class = "zulake_error_corrupt_log")
  out <- capture.output(print(tbl))
  expect_true(any(grepl("records: +unknown \\(the statistics cannot be read\\)", out)))
})

test_that("statistics that break the protocol are a corrupt log, and stats = FALSE still lists the files", {
  bad <- c(
    "not json",
    "[1,2]",
    '{\\"minValues\\":[1]}',
    '{\\"minValues\\":{\\"d\\":\\"2024-13-45\\"}}',
    '{\\"maxValues\\":{\\"ts\\":\\"yesterday\\"}}',
    '{\\"minValues\\":{\\"id\\":\\"ten\\"}}',
    '{\\"minValues\\":{\\"n\\":1.5}}'
  )
  for (stats in bad) {
    lines <- c(raw_header(c(id = "long", d = "date", ts = "timestamp", n = "integer")),
               raw_add("a.parquet", stats = stats))
    tbl <- lake_open(raw_table(lines))
    err <- tryCatch(lake_files(tbl), error = identity)
    expect_s3_class(err, "zulake_error_corrupt_log")
    expect_identical(nrow(lake_files(tbl, stats = FALSE)), 1L, label = stats)
  }
  # Empty statistics are no statistics.
  none <- lake_files(lake_open(raw_table(c(raw_header(), raw_add("a.parquet")))))
  empty <- lake_files(lake_open(raw_table(c(raw_header(), raw_add("a.parquet", stats = "{}")))))
  expect_identical(empty[c("num_records", "min", "max", "null_count")], none[c("num_records", "min", "max", "null_count")])
  # An empty statistics object is an empty object, as zujson parses one.
  stats <- '{\\"numRecords\\":1,\\"minValues\\":{}}'
  files <- lake_files(lake_open(raw_table(c(raw_header(), raw_add("a.parquet", stats = stats)))))
  expect_identical(files$min[[1L]], zujson::json_parse("{}"))
  expect_identical(files$num_records, 1)
  # A statistic for a column the schema does not have is kept as it is.
  lines <- c(raw_header(), raw_add("a.parquet", stats = '{\\"minValues\\":{\\"gone\\":12,\\"also\\":\\"x\\",\\"f\\":1.5}}'))
  expect_identical(lake_files(lake_open(raw_table(lines)))$min[[1L]], list(gone = 12, also = "x", f = 1.5))
})

test_that("a partition value no calendar holds is a corrupt log when the snapshot is built (#53)", {
  for (case in list(c("date", "2024-02-31"), c("timestamp", "2024-02-30 10:00:00"))) {
    path <- hand_table(c(protocol_line(), metadata_line(c(id = "long", p = case[1L]), partition = "p"),
                         add_line("a.parquet", partition = list(p = case[2L]))))
    expect_no_snapshot(lake_open(path), "zulake_error_corrupt_log")
  }
})

test_that("partition values of every type parse as the protocol serialises them", {
  types <- c(b = "byte", s = "short", i = "integer", l = "long", f = "float", d = "double", t = "boolean",
             dt = "date", ts = "timestamp", ntz = "timestamp_ntz", dec = "decimal(10,2)", str = "string")
  values <- list(b = "-128", s = "32767", i = "-2147483648", l = "-9007199254740991", f = "-Infinity", d = "1.5e-300",
                 t = "TRUE", dt = "0001-01-01", ts = "2024-01-02 03:04:05.123456", ntz = "2024-01-02T03:04:05",
                 dec = "-0.10", str = "")
  path <- hand_table(c(protocol_line(), metadata_line(types, partition = names(types)),
                       add_line("a.parquet", partition = values)))
  p <- lake_files(lake_open(path))$partition[[1L]]
  expect_identical(p$b, -128L)
  expect_identical(p$s, 32767L)
  expect_identical(p$i, -2147483648)
  expect_identical(p$l, -9007199254740991)
  expect_identical(p$f, -Inf)
  expect_identical(p$d, 1.5e-300)
  expect_identical(p$t, TRUE)
  expect_identical(oracle_canon(p$dt), "0001-01-01")
  expect_identical(oracle_canon(p$ts), "2024-01-02T03:04:05.123456")
  expect_identical(oracle_canon(p$ntz), "2024-01-02T03:04:05.000000")
  expect_identical(p$dec, "-0.10")
  expect_identical(p$str, NA_character_)
  # Offsets move a timestamp to UTC.
  path <- hand_table(c(protocol_line(), metadata_line(c(ts = "timestamp"), partition = "ts"),
                       add_line("a.parquet", partition = list(ts = "2024-01-02T03:04:05+01:30"))))
  expect_identical(oracle_canon(lake_files(lake_open(path))$partition[[1L]]$ts), "2024-01-02T01:34:05.000000")
})

test_that("a deletion vector without a cardinality is a corrupt log", {
  header <- raw_header()
  header[1L] <- paste0('{"protocol":{"minReaderVersion":3,"minWriterVersion":7,',
                       '"readerFeatures":["deletionVectors"],"writerFeatures":["deletionVectors"]}}')
  dv <- ',"deletionVector":{"storageType":"u","pathOrInlineDv":"vBn[lx{q8@P<9BNH/isA","offset":1,"sizeInBytes":36}'
  tbl <- lake_open(raw_table(c(header, raw_add("a.parquet", stats = '{\\"numRecords\\":10}', extra = dv))))
  err <- tryCatch(lake_count(tbl), error = identity)
  expect_s3_class(err, "zulake_error_corrupt_log")
  expect_match(conditionMessage(err), "cardinality", fixed = TRUE)
})

test_that("results do not depend on the locale or on number formatting options", {
  tbl <- lake_open(fixture_table("zl-partitioned"))
  ref_files <- lake_files(tbl)
  ref_parts <- lake_partitions(tbl)
  ref_print <- capture.output(print(tbl))
  withr::local_options(OutDec = ",", scipen = -5, digits = 3)
  withr::local_collate("C")
  expect_identical(lake_files(lake_open(fixture_table("zl-partitioned"))), ref_files)
  expect_identical(lake_partitions(tbl), ref_parts)
  expect_identical(capture.output(print(tbl)), ref_print)
  expect_identical(lake_files(tbl, filter = p_str == factor("a"))$path, ref_files$path[2:3])
  expect_identical(lake_files(tbl, filter = p_str %in% factor(c("a", "café")))$path, ref_files$path[2:4])
})

test_that("lake_partitions() keeps every distinct value the log writes, as deltalake does (#55)", {
  # deltalake 1.7.0's partitions() for this log: eight rows, one per text.
  values <- list("0.3", "0.30000000000000004", "0", "-0", "NaN", NULL, "1", "1.0")
  adds <- vapply(seq_along(values), function(i) {
    add_line(sprintf("f%d.parquet", i), partition = if (is.null(values[[i]])) list() else list(p = values[[i]]))
  }, "")
  tbl <- lake_open(hand_table(c(protocol_line(), metadata_line(c(id = "long", p = "double"), partition = "p"), adds,
                                add_line("again.parquet", partition = list(p = "0.3")))))
  p <- lake_partitions(tbl)$p
  expect_length(p, 8L)
  expect_identical(sum(is.na(p) & !is.nan(p)), 1L)
  expect_identical(sum(is.nan(p)), 1L)
  expect_identical(sum(p %in% 0.3 & p == 0.3), 1L)
  expect_identical(sum(p == 0.30000000000000004 & p != 0.3, na.rm = TRUE), 1L)
  expect_identical(sum(p == 0 & 1 / p < 0, na.rm = TRUE), 1L)
  expect_identical(sum(p == 0 & 1 / p > 0, na.rm = TRUE), 1L)
  expect_identical(sum(p == 1, na.rm = TRUE), 2L)
  # A timestamp partition below the second, and long partitions ordered by
  # value in both int64 modes.
  ts <- c("2024-01-01 00:00:00.000001", "2024-01-01 00:00:00.000002")
  tbl <- lake_open(hand_table(c(protocol_line(), metadata_line(c(id = "long", p = "timestamp"), partition = "p"),
                                vapply(ts, function(x) add_line(paste0(x, ".parquet"), partition = list(p = x)), ""))))
  expect_identical(nrow(lake_partitions(tbl)), 2L)
  longs <- c("-10", "-1", "0", "1", "9", "10", "100", "9223372036854775807", "-9223372036854775807")
  tbl <- lake_open(hand_table(c(protocol_line(), metadata_line(c(id = "long", p = "long"), partition = "p"),
                                vapply(sample(longs), function(x) add_line(paste0(x, ".parquet"), partition = list(p = x)), ""))))
  skip_if_not_installed("bit64")
  expect_identical(as.character(lake_partitions(tbl, int64 = "integer64")$p),
                   c("-9223372036854775807", "-10", "-1", "0", "1", "9", "10", "100", "9223372036854775807"))
  small <- lake_open(hand_table(c(protocol_line(), metadata_line(c(id = "long", p = "long"), partition = "p"),
                                  vapply(sample(longs[1:7]), function(x) add_line(paste0(x, ".parquet"), partition = list(p = x)), ""))))
  expect_identical(as.character(lake_partitions(small, int64 = "integer64")$p), as.character(lake_partitions(small)$p))
})

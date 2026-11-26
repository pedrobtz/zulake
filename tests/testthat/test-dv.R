# Deletion vectors (design section 4.4, D9, D12): lake_deletion_vectors()
# against deltalake 1.7.0's deletion_vectors(), reads that drop the rows
# they mark against deltalake's reads, Z85 against RFC 32 and an encoder in
# the test, CRC-32 against zlib, and zuroar absent.

test_that("deletion-vector rows equal deltalake's deletion_vectors() at every version of every fixture", {
  skip_if_not_installed("zuroar")
  seen <- 0L
  for (case in inspect_cases()) {
    tbl <- case_snapshot(case)
    label <- paste(case$table, case$version)
    got <- lake_deletion_vectors(tbl)
    want <- oracle_field(case$table, case$version, "deletion_vectors")
    files <- suppressWarnings(lake_files(tbl, stats = TRUE))
    expect_identical(nrow(got), length(want), label = label)
    paths <- files$path[match(got$uri, files$uri)]
    for (w in want) {
      k <- match(w$path, paths)
      expect_false(is.na(k), label = paste(label, w$path))
      expect_identical(got$rows[[k]], as.numeric(unlist(w$deleted_rows)), label = paste(label, w$path))
      expect_identical(got$cardinality[k], as.numeric(length(unlist(w$deleted_rows))))
      # The selection vector covers the file's rows.
      expect_identical(files$num_records[match(w$path, files$path)], as.numeric(w$selection_vector_length))
      seen <- seen + 1L
    }
    # The descriptors are lake_files()' own.
    desc <- Filter(Negate(is.null), files$deletion_vector)
    expect_identical(got$storage_type, vapply(desc, function(d) d$storageType, ""))
    expect_identical(got$size_in_bytes, vapply(desc, function(d) d$sizeInBytes, 0))
  }
  expect_identical(seen, 3L)
})

test_that("reads of every deletion-vector fixture equal deltalake's: no marked row appears", {
  skip_if_not_installed("zuroar")
  for (table in c("deletion_vectors", "table-with-dv-small", "table-with-dv-small-inline")) {
    for (v in oracle_versions(table)) {
      tbl <- lake_open(fixture_table(table), version = v)
      got <- lake_read(tbl)
      expect_read_oracle(got, table, v)
      expect_identical(lake_count(tbl), as.numeric(nrow(got)))
      expect_oracle(lake_count(tbl), table, v, "count")
      # The rows that are gone are exactly the marked ones.
      dv <- lake_deletion_vectors(tbl)
      whole <- read_each_file_raw(tbl)
      for (k in seq_len(nrow(dv))) {
        i <- match(dv$uri[k], lake_files(tbl, stats = FALSE)$uri)
        marked <- whole[[i]][dv$rows[[k]] + 1, , drop = FALSE]
        expect_identical(nrow(merge(marked, got)), 0L, label = paste(table, v))
      }
      pieces <- list()
      lake_walk(tbl, function(p) pieces[[length(pieces) + 1L]] <<- p)
      if (nrow(got)) expect_identical(do.call(rbind, pieces), got)
    }
  }
})

test_that("a filter and a deletion vector together keep the unmarked matching rows", {
  skip_if_not_installed("zuroar")
  tbl <- lake_open(fixture_table("table-with-dv-small"))
  full <- lake_read(tbl)
  for (expr in list(quote(value > 4), quote(value %in% c(0, 9, 5)), quote(value %% 2 == 0), quote(value < 0))) {
    expect_identical(eval(bquote(lake_read(tbl, filter = .(expr)))), r_subset(full, expr), label = deparse(expr))
  }
  expect_false(any(c(0L, 9L) %in% full$value))
})

test_that("Z85 decodes RFC 32's test vector, the protocol's examples, and random bytes an independent encoder wrote", {
  expect_identical(z85_decode("HelloWorld"), as.raw(c(0x86, 0x4F, 0xD2, 0x6F, 0xB5, 0x59, 0xF7, 0x5B)))
  expect_identical(z85_decode(""), raw())
  withr::local_seed(20261130)
  for (n in c(4L, 8L, 16L, 40L, 400L)) {
    bytes <- as.raw(sample(0:255, n, replace = TRUE))
    expect_identical(z85_decode(test_z85_encode(bytes)), bytes)
  }
  # Every alphabet character in every position.
  bytes <- as.raw(c(rep(0xff, 4), rep(0, 4), 0:255))
  expect_identical(z85_decode(test_z85_encode(bytes)), bytes)
  # The protocol's Example 1: a prefix and a UUID.
  text <- "ab^-aqEH.-t@S}K{vb[*k^"
  expect_identical(dv_relative_path(substr(text, 1L, 2L), z85_decode(substr(text, 3L, 22L))),
                   "ab/deletion_vector_d2c639aa-8816-431a-aaf6-d3fe2512ff61.bin")
  expect_identical(dv_relative_path("", z85_decode("vBn[lx{q8@P<9BNH/isA")),
                   "deletion_vector_61d16c75-6994-46b7-a15b-8b538852e50e.bin")
  # Malformed text.
  for (bad in c("Hell", "HelloWorl", "Hell\"World", "Hello World", "#####")) {
    expect_error(z85_decode(bad), class = "zulake_error_z85", label = bad)
  }
  # "%nSc0" is 2^32 - 1, the largest group; one more is past 32 bits.
  expect_identical(z85_decode("%nSc0"), as.raw(rep(0xff, 4)))
  expect_identical(z85_decode("%nSb#"), as.raw(c(0xff, 0xff, 0xff, 0xfe)))
  expect_error(z85_decode("%nSc1"), class = "zulake_error_z85")
})

test_that("the protocol's inline example decodes to its rows, in a format zulake refuses", {
  skip_if_not_installed("zuroar")
  # Example 3 of the protocol's descriptor schema is in Delta's "native"
  # format (magic 1681511376, big-endian, then a bucket count and a 32-bit
  # bitmap), which the protocol's Deletion Vector Format does not define;
  # its Z85 decodes to that bitmap, whose rows are the example's.
  text <- "wi5b=000010000siXQKl0rr91000f55c8Xg0@@D72lkbi5=-{L"
  bytes <- z85_decode(text)
  expect_length(bytes, 40L)
  expect_identical(be_uint32(bytes[1:4]), 1681511376)
  expect_identical(as.double(zuroar::roar_unserialize(bytes[13:40])), c(3, 4, 7, 11, 18, 29))
  dv <- list(storageType = "i", pathOrInlineDv = text, sizeInBytes = 40L, cardinality = 6L)
  tbl <- lake_open(dv_table(dv, n = 30L))
  err <- tryCatch(lake_read(tbl), error = identity)
  expect_s3_class(err, "zulake_error_corrupt_log")
  expect_match(conditionMessage(err), "magic number", fixed = TRUE)
  # The same rows in the protocol's format read.
  tbl <- lake_open(dv_table(inline_dv(dv_bytes(c(3, 4, 7, 11, 18, 29)), 6L), n = 30L))
  expect_identical(lake_deletion_vectors(tbl)$rows[[1L]], c(3, 4, 7, 11, 18, 29))
  expect_identical(lake_read(tbl)$id, setdiff(0:29, c(3, 4, 7, 11, 18, 29)) + 0)
})

test_that("CRC-32 equals zlib's", {
  expect_identical(crc32(charToRaw("123456789")), 3421780262)
  expect_identical(crc32(raw()), 0)
  withr::local_seed(20261131)
  for (n in c(1L, 2L, 3L, 36L, 1000L, 5000L)) {
    bytes <- as.raw(sample(0:255, n, replace = TRUE))
    expect_identical(crc32(bytes), test_crc32(bytes), label = n)
  }
  expect_identical(crc32(as.raw(rep(0xff, 64))), test_crc32(as.raw(rep(0xff, 64))))
})

test_that("vectors at a relative path with a prefix, at an absolute path and at a file: URI are read", {
  skip_if_not_installed("zuroar")
  rows <- c(1, 4, 5)
  first <- dv_bytes(c(0, 2))
  vec <- dv_bytes(rows)
  offsets <- c(1, 1 + 4 + length(first) + 4)
  uuid <- random_uuid()
  for (where in c("prefix", "plain", "absolute", "uri")) {
    rel <- dv_relative_path(if (where == "prefix") "x7" else "", uuid)
    outside <- file.path(normalizePath(withr::local_tempdir(), winslash = "/"), "dv file.bin")
    text <- switch(where,
      prefix = paste0("x7", test_z85_encode(uuid)),
      plain = test_z85_encode(uuid),
      absolute = outside,
      uri = paste0(if (startsWith(outside, "/")) "file://" else "file:///", gsub(" ", "%20", outside, fixed = TRUE))
    )
    dv <- list(storageType = if (where %in% c("prefix", "plain")) "u" else "p", pathOrInlineDv = text,
               offset = offsets[2L], sizeInBytes = length(vec), cardinality = length(rows))
    path <- dv_table(dv)
    target <- if (where %in% c("prefix", "plain")) file.path(path, rel) else outside
    expect_identical(write_dv_file(target, list(first, vec)), offsets)
    tbl <- lake_open(path)
    expect_identical(lake_deletion_vectors(tbl)$rows[[1L]], rows, label = where)
    expect_identical(lake_read(tbl)$id, setdiff(0:9, rows) + 0, label = where)
    expect_identical(lake_count(tbl), 7)
  }
  # Another scheme is a zulake_error_uri.
  dv <- list(storageType = "p", pathOrInlineDv = "abfss://lake@account.dfs.core.windows.net/t/dv.bin",
             offset = 1L, sizeInBytes = length(vec), cardinality = 3L)
  expect_error(lake_read(lake_open(dv_table(dv))), class = "zulake_error_uri")
})

test_that("an offset absent from a file-stored descriptor is read as 0, as the protocol says", {
  skip_if_not_installed("zuroar")
  vec <- dv_bytes(c(2, 3))
  uuid <- random_uuid()
  rel <- dv_relative_path("", uuid)
  dv <- list(storageType = "u", pathOrInlineDv = test_z85_encode(uuid), offset = 1L,
             sizeInBytes = length(vec), cardinality = 2L)
  path <- dv_table(dv)
  write_dv_file(file.path(path, rel), list(vec))
  expect_identical(lake_deletion_vectors(lake_open(path))$rows[[1L]], c(2, 3))
  # Without the offset, the size is read from byte 0, the format version.
  dv$offset <- NULL
  path <- dv_table(dv)
  write_dv_file(file.path(path, rel), list(vec))
  expect_error(lake_deletion_vectors(lake_open(path)), class = "zulake_error_corrupt_log")
})

test_that("lake_deletion_vectors() has the documented columns, files and rows arguments", {
  skip_if_not_installed("zuroar")
  tbl <- lake_open(fixture_table("table-with-dv-small-inline"))
  dv <- lake_deletion_vectors(tbl)
  expect_identical(names(dv), c("uri", "storage_type", "path_or_inline_dv", "offset", "size_in_bytes", "cardinality", "rows"))
  expect_identical(dv$offset, NA_real_)
  expect_type(dv$rows, "list")
  files <- lake_files(tbl, stats = FALSE)
  expect_identical(lake_deletion_vectors(tbl, files = files$path), dv)
  expect_identical(lake_deletion_vectors(tbl, files = files$uri), dv)
  expect_identical(lake_deletion_vectors(tbl, rows = FALSE), dv[names(dv) != "rows"])
  # A file without a vector gives no row; none gives the same columns.
  none <- lake_deletion_vectors(lake_open(fixture_table("zl-basic")))
  expect_identical(lapply(none, class), lapply(dv, class))
  expect_identical(nrow(none), 0L)
  expect_identical(nrow(lake_deletion_vectors(tbl, files = character())), 0L)
  for (bad in list("nope.parquet", NA_character_, 1, c(files$path, NA))) {
    expect_error(lake_deletion_vectors(tbl, files = bad), class = "zulake_error_argument")
  }
  for (bad in list(NA, "yes", c(TRUE, FALSE), 1)) {
    expect_error(lake_deletion_vectors(tbl, rows = bad), class = "zulake_error_argument")
  }
  expect_error(lake_deletion_vectors("x"), class = "zulake_error_argument")
})

test_that("rows = FALSE reads nothing and needs no zuroar", {
  tbl <- lake_open(fixture_table("deletion_vectors"))
  env <- new.env()
  tbl$storage <- recording_storage(tbl$storage, env)
  local_mocked_bindings(zuroar_available = function() FALSE)
  dv <- lake_deletion_vectors(tbl, rows = FALSE)
  expect_identical(nrow(dv), 1L)
  expect_identical(dv$cardinality, 4)
  expect_identical(dv$offset, 1)
  expect_length(env$calls, 0L)
})

test_that("without zuroar, a read that needs a deletion vector is a classed error naming it, before any data is read", {
  local_mocked_bindings(zuroar_available = function() FALSE)
  for (table in c("deletion_vectors", "table-with-dv-small", "table-with-dv-small-inline")) {
    tbl <- lake_open(fixture_table(table))
    env <- new.env()
    tbl$storage <- remote_storage(tbl$storage, env)
    for (f in list(function() lake_read(tbl), function() lake_walk(tbl, identity),
                   function() lake_deletion_vectors(tbl))) {
      err <- tryCatch(f(), error = identity)
      expect_s3_class(err, "zulake_error_missing_package")
      expect_s3_class(err, "zulake_error")
      expect_identical(err$package, "zuroar")
      expect_match(conditionMessage(err), "zuroar", fixed = TRUE)
    }
    expect_length(env$calls, 0L)
    # The log alone still answers.
    expect_identical(lake_count(tbl), as.numeric(oracle_field(table, max(oracle_versions(table)), "count")))
  }
  # A table, or a version, or the files a filter keeps, without a vector
  # read as before.
  expect_read_oracle(lake_read(lake_open(fixture_table("table-with-dv-small"), version = 0)), "table-with-dv-small", 0)
  tbl <- lake_open(fixture_table("zl-basic"))
  expect_identical(as.numeric(nrow(lake_read(tbl))), lake_count(tbl))
})

test_that("a deletion vector of rows up to 2^53 - 1 is returned exactly; from 2^53 it is a classed error", {
  skip_if_not_installed("zuroar")
  for (top in c("9007199254740990", "9007199254740991", "9007199254740992", "9007199254740993", "18446744073709551614")) {
    vec <- dv_bytes(c("1", top))
    tbl <- lake_open(dv_table(inline_dv(vec, 2L)))
    if (top %in% c("9007199254740990", "9007199254740991")) {
      expect_identical(lake_deletion_vectors(tbl)$rows[[1L]], c(1, as.numeric(top)), label = top)
      # The file has 10 rows: such a vector is a corrupt one.
      expect_error(lake_read(tbl), class = "zulake_error_corrupt_log")
    } else {
      err <- tryCatch(lake_deletion_vectors(tbl), error = identity)
      expect_s3_class(err, "zulake_error_int64")
      expect_identical(err$value, top)
      expect_error(lake_read(tbl), class = "zulake_error_int64")
    }
    expect_identical(lake_deletion_vectors(tbl, rows = FALSE)$cardinality, 2)
  }
})

test_that("a vector that disagrees with its descriptor or its data file is a corrupt log, and no rows are returned", {
  skip_if_not_installed("zuroar")
  check <- function(dv, n = 10L) {
    tbl <- lake_open(dv_table(dv, n = n))
    called <- FALSE
    expect_error(lake_read(tbl), class = "zulake_error_corrupt_log")
    expect_error(lake_walk(tbl, function(p) called <<- TRUE), class = "zulake_error_corrupt_log")
    expect_false(called)
    invisible(tbl)
  }
  vec <- dv_bytes(c(0, 9))
  # The cardinality is not the bitmap's.
  check(inline_dv(vec, 3L))
  # A row past the end of the data file.
  check(inline_dv(dv_bytes(c(0, 10)), 2L))
  # A magic number that differs, inline, where no checksum catches it first.
  check(inline_dv(dv_bytes(c(0, 9), magic = 1681511378), 2L))
  # Inline bytes fewer than sizeInBytes.
  short <- inline_dv(vec, 2L)
  short$sizeInBytes <- 44L
  check(short)
  # Not Z85.
  check(list(storageType = "i", pathOrInlineDv = "~~~~~", sizeInBytes = 4L, cardinality = 0L))
  # Not a Roaring bitmap after the magic number.
  check(inline_dv(c(vec[1:4], as.raw(rep(0xff, 8))), 2L))
  # sizeInBytes below the magic number's 4 bytes.
  bad_size <- inline_dv(vec, 2L)
  bad_size$sizeInBytes <- 3L
  check(bad_size)
  # In a file: format version 2, a stored size that is not the log's, a UUID
  # too short, a file that does not exist.
  for (case in c("version", "size", "short", "missing")) {
    uuid <- random_uuid()
    rel <- dv_relative_path("", uuid)
    dv <- list(storageType = "u", pathOrInlineDv = test_z85_encode(uuid), offset = 1L,
               sizeInBytes = length(vec), cardinality = 2L)
    # 19 characters, one short of a UUID's 20 (20 and 22 read, above).
    if (case == "short") dv$pathOrInlineDv <- substring(test_z85_encode(uuid), 2L)
    if (case == "size") dv$sizeInBytes <- length(vec) - 4L
    tbl <- check(dv)
    if (case != "missing") {
      write_dv_file(file.path(tbl$storage$root, rel), list(vec), version = if (case == "version") 2L else 1L)
      expect_error(lake_read(tbl), class = "zulake_error_corrupt_log", label = case)
      expect_error(lake_deletion_vectors(tbl), class = "zulake_error_corrupt_log", label = case)
      expect_identical(nrow(lake_deletion_vectors(tbl, rows = FALSE)), 1L)
    }
  }
})

test_that("a deletion vector of a file that pruning drops is never read", {
  skip_if_not_installed("zuroar")
  path <- local_fixture_copy("table-with-dv-small")
  tbl <- lake_open(path)
  file <- lake_files(tbl, stats = FALSE)
  # A second file, without a vector, holding values above the first's.
  qio::write_parquet(data.frame(value = 100:104), file.path(path, "other.parquet"))
  write_commit(path, 2, json_line(list(add = list(
    path = "other.parquet", partitionValues = structure(list(), names = character()),
    size = file.size(file.path(path, "other.parquet")), modificationTime = 0, dataChange = TRUE,
    stats = '{"numRecords":5,"minValues":{"value":100},"maxValues":{"value":104},"nullCount":{"value":0}}'
  ))))
  tbl <- lake_open(path)
  env <- new.env()
  tbl$storage <- recording_storage(tbl$storage, env)
  expect_identical(lake_read(tbl, filter = value >= 100)$value, 100:104)
  expect_false(any(grepl("deletion_vector", env$calls)))
  expect_identical(nrow(lake_read(tbl)), 13L)
  expect_true(any(grepl("deletion_vector", env$calls)))
})

# lake_read(), lake_walk() and lake_count(footers = TRUE) (design sections
# 4.3, 5 and 7), against deltalake 1.7.0's full reads.

test_that("full reads of every fixture equal deltalake's", {
  cases <- read_cases()
  expect_gt(length(cases), 80L)
  for (case in cases) {
    tbl <- case_snapshot(case)
    got <- collect_warnings(lake_read(tbl))
    if (case$table == "zl-types") {
      # Columns qio cannot return are left out by name (design section 7);
      # qio warns about the int32 and int64 values it cannot hold.
      skipped <- vapply(Filter(function(w) inherits(w, "zulake_warning_column_skipped"), got$warnings),
                        function(w) w$column, "")
      expect_setequal(skipped, c("dec38", "st", "li", "mp"))
      expect_read_oracle(got$value, case$table, case$version, skipped = skipped)
    } else if (case$table == "zl-int32-min") {
      # qio warns that it read the int32 -2^31 as NA (#79).
      expect_length(got$warnings, 1L)
      expect_match(conditionMessage(got$warnings[[1L]]), "INT32 values in column 'i32' were coerced to NA", fixed = TRUE)
      expect_read_oracle(got$value, case$table, case$version)
    } else {
      expect_length(got$warnings, 0L)
      expect_read_oracle(got$value, case$table, case$version)
    }
  }
})

test_that("int64 = \"integer64\" reads 64-bit data and partition values exactly", {
  skip_if_not_installed("bit64")
  tbl <- lake_open(fixture_table("zl-types"))
  got <- collect_warnings(lake_read(tbl, int64 = "integer64"))
  expect_s3_class(got$value$i64, "integer64")
  expect_read_oracle(got$value, "zl-types", 0, int64 = "integer64", skipped = c("dec38", "st", "li", "mp"))
  # A long partition column, as integer64; past 2^53 - 1 as a double it is
  # an error, as in lake_files().
  path <- local_fixture_copy("zl-basic")
  files <- lake_files(lake_open(path), stats = FALSE)
  big <- "9007199254740993"
  write_commit(path, 5, c(
    metadata_line(c(id = "long", label = "string", x = "double", p = "long"), partition = "p"),
    vapply(files$path, function(p) remove_line(p), ""),
    add_line(files$path[1L], partition = list(p = big), size = files$size_bytes[1L])
  ))
  tbl <- lake_open(path)
  expect_error(lake_read(tbl), class = "zulake_error_int64")
  r <- lake_read(tbl, int64 = "integer64")
  expect_identical(unique(as.character(r$p)), big)
  expect_identical(nrow(lake_read(tbl, filter = p == "9007199254740993", int64 = "integer64")), nrow(r))
  expect_identical(nrow(lake_read(tbl, filter = p > 9007199254740992, int64 = "integer64")), nrow(r))
  expect_identical(nrow(lake_read(tbl, filter = p < "9007199254740993.5", int64 = "integer64")), nrow(r))
  expect_identical(nrow(lake_read(tbl, filter = p > "9007199254740993", int64 = "integer64")), 0L)
})

test_that("a nested column is left out with a classed warning, or a classed error when asked for", {
  tbl <- lake_open(fixture_table("zl-types"))
  got <- collect_warnings(lake_read(tbl))
  w <- Filter(function(w) inherits(w, "zulake_warning_column_skipped"), got$warnings)
  expect_length(w, 4L)
  for (x in w) {
    expect_s3_class(x, "zulake_warning")
    expect_type(x$reason, "character")
    expect_match(conditionMessage(x), x$column, fixed = TRUE)
  }
  reasons <- stats::setNames(vapply(w, function(x) x$reason, ""), vapply(w, function(x) x$column, ""))
  expect_match(reasons[["st"]], "nested column (struct)", fixed = TRUE)
  expect_match(reasons[["li"]], "nested column (array)", fixed = TRUE)
  expect_match(reasons[["mp"]], "nested column (map)", fixed = TRUE)
  expect_match(reasons[["dec38"]], "decimal precision 38 > 15", fixed = TRUE)
  # The flat columns are deltalake's, in the schema's order.
  expect_identical(names(got$value), setdiff(lake_schema(tbl)$name, c("dec38", "st", "li", "mp")))
  for (col in c("st", "li", "mp", "dec38")) {
    err <- tryCatch(lake_read(tbl, columns = c("s", col)), error = identity)
    expect_s3_class(err, "zulake_error_column_unreadable")
    expect_identical(err$column, col)
    expect_identical(err$reason, reasons[[col]])
    err <- tryCatch(eval(bquote(lake_read(tbl, columns = "s", filter = !is.na(.(as.symbol(col)))))), error = identity)
    expect_s3_class(err, "zulake_error_column_unreadable")
    expect_identical(err$column, col)
  }
  # Asking only for readable columns warns about nothing.
  got <- collect_warnings(lake_read(tbl, columns = c("dec", "s")))
  expect_length(got$warnings, 0L)
  expect_identical(names(got$value), c("dec", "s"))
})

test_that("the columns that cannot be read are found from qio's read plan, not from qio dropping them", {
  # A table whose schema says `long` for a column its file stores nested:
  # only the read plan can tell.
  path <- local_fixture_copy("zl-types")
  tbl <- lake_open(path)
  fields <- lake_schema(tbl)
  types <- stats::setNames(fields$type, fields$name)
  types[["st"]] <- "long"
  types[["li"]] <- "string"
  types[["mp"]] <- "integer"
  types[["dec38"]] <- "double"
  file <- lake_files(tbl, stats = FALSE)
  write_commit(path, 1, c(metadata_line(types), remove_line(file$path), add_line(file$path, size = file$size_bytes)))
  tbl <- lake_open(path)
  got <- suppressMessages(collect_warnings(lake_read(tbl)))
  w <- Filter(function(w) inherits(w, "zulake_warning_column_skipped"), got$warnings)
  expect_setequal(vapply(w, function(x) x$column, ""), c("st", "li", "mp"))
  for (x in w) expect_match(x$reason, "nested column", fixed = TRUE)
  expect_true("dec38" %in% names(got$value))
  expect_error(lake_read(tbl, columns = "st"), class = "zulake_error_column_unreadable")
  # The decimal read as a double the schema did not vet: qio's message stays.
  expect_message(suppressWarnings(lake_read(tbl, columns = "dec38")), "DECIMAL")
  expect_silent(lake_read(tbl, columns = "dec"))
})

test_that("decimals of precision 15 or less are doubles, data and partition columns alike", {
  tbl <- lake_open(fixture_table("zl-types"))
  r <- lake_read(tbl, columns = "dec")
  expect_type(r$dec, "double")
  text <- unlist(oracle_field("zl-types", 0, c("read", "columns", "dec")))
  expect_setequal(sprintf("%.2f", r$dec[!is.na(r$dec)]), text[!is.na(text)])
  path <- local_fixture_copy("zl-basic")
  files <- lake_files(lake_open(path), stats = FALSE)
  write_commit(path, 5, c(
    metadata_line(c(id = "long", label = "string", x = "double", p = "decimal(15,3)", w = "decimal(16,3)"),
                  partition = c("p", "w")),
    vapply(files$path, function(p) remove_line(p), ""),
    add_line(files$path[1L], partition = list(p = "123456789012.345", w = "1.5"), size = files$size_bytes[1L]),
    add_line(files$path[2L], partition = list(p = "-0.001", w = "2"), size = files$size_bytes[2L])
  ))
  tbl <- lake_open(path)
  expect_warning(r <- lake_read(tbl), class = "zulake_warning_column_skipped")
  expect_false("w" %in% names(r))
  expect_setequal(unique(r$p), c(123456789012.345, -0.001))
  expect_error(lake_read(tbl, columns = "w"), class = "zulake_error_column_unreadable")
  expect_error(lake_read(tbl, columns = "id", filter = w > 1), class = "zulake_error_column_unreadable")
  # lake_files() compares a wide decimal partition value exactly.
  expect_identical(nrow(lake_files(tbl, filter = w > 1.5, stats = FALSE)), 1L)
  expect_identical(nrow(lake_files(tbl, filter = w > "1.4999999999999999999", stats = FALSE)), 2L)
  expect_identical(nrow(lake_read(tbl, columns = "id", filter = p == "-0.0010")),
                   sum(suppressWarnings(lake_read(tbl))$p == -0.001))
})

test_that("name-mode column mapping reads physical columns under logical names, as deltalake does", {
  for (table in c("column_mapping", "table_with_column_mapping")) {
    for (v in oracle_versions(table)) {
      tbl <- lake_open(fixture_table(table), version = v)
      expect_identical(tbl$column_mapping, "name")
      got <- lake_read(tbl)
      expect_read_oracle(got, table, v)
      expect_identical(names(got), lake_schema(tbl)$name)
      expect_false(any(startsWith(names(got), "col-")))
    }
  }
  # Filters by logical name: pruning uses statistics and partition values
  # keyed by physical name, and the rows equal R's subset.
  local_hostile_locale()
  tbl <- lake_open(fixture_table("column_mapping"))
  full <- lake_read(tbl)
  schema <- lake_schema(tbl)
  expect_true(all(schema$physical_name != schema$name))
  for (expr in list(quote(letter == "a"), quote(new_int > 500), quote(is.na(date)), quote(new_int %in% c(25, 228)),
                    quote(nchar(letter) == 1 & new_int < 300))) {
    expect_identical(eval(bquote(lake_read(tbl, filter = .(expr)))), r_subset(full, expr), label = deparse(expr))
  }
  expect_identical(nrow(lake_files(tbl, filter = new_int > 1e9)), 0L)
  tbl <- lake_open(fixture_table("table_with_column_mapping"))
  full <- lake_read(tbl)
  got <- lake_read(tbl, filter = `Company Very Short` == "BME")
  expect_identical(got, r_subset(full, quote(`Company Very Short` == "BME")))
  expect_gt(nrow(got), 0L)
  # A column the files do not have (added after they were written) reads as
  # NA, found by physical name.
  path <- local_fixture_copy("column_mapping")
  tbl <- lake_open(path)
  s <- lake_schema(tbl)
  types <- stats::setNames(s$type, s$name)
  physical <- stats::setNames(s$physical_name, s$name)
  write_commit(path, 4, metadata_line(c(types, extra = "string"), physical = c(physical, extra = "col-extra"),
                                      configuration = list(delta.columnMapping.mode = "name")))
  r <- lake_read(lake_open(path))
  expect_true(all(is.na(r$extra)))
  expect_identical(r[names(full <- lake_read(tbl))], full)
})

test_that("timestamp_ntz columns read as POSIXct in UTC, equal to deltalake's", {
  tbl <- lake_open(fixture_table("zl-types"))
  expect_true("timestampNtz" %in% lake_protocol(tbl)$name)
  expect_identical(lake_schema(tbl)$type[lake_schema(tbl)$name == "ntz"], "timestamp_ntz")
  r <- lake_read(tbl, columns = "ntz")
  expect_s3_class(r$ntz, "POSIXct")
  expect_identical(attr(r$ntz, "tzone"), "UTC")
  others <- setdiff(names(oracle_field("zl-types", 0, c("read", "columns"))), "ntz")
  expect_read_oracle(r, "zl-types", 0, skipped = others)
  text <- unlist(oracle_field("zl-types", 0, c("read", "columns", "ntz")))
  expect_false(any(endsWith(text[!is.na(text)], "Z")))
  expect_gt(sum(!is.na(r$ntz)), 0L)
  # The same instants whatever the session's time zone.
  tbl <- lake_open(fixture_table("zl-types"))
  a <- withr::with_timezone("America/New_York", lake_read(tbl, columns = "ntz"))
  b <- withr::with_timezone("Asia/Tokyo", lake_read(tbl, columns = "ntz"))
  expect_identical(a, b)
})

test_that("lake_walk() pieces bound together equal lake_read(), one piece per file with rows", {
  for (case in list(list(table = "zl-partitioned", filter = quote(p_int >= 2 | is.na(p_str))),
                    list(table = "zl-checkpoint", filter = quote(id %% 2 == 0)),
                    list(table = "zl-basic", filter = NULL),
                    list(table = "delta-0.8.0-partitioned", filter = quote(year == "2021")))) {
    tbl <- lake_open(fixture_table(case$table))
    pieces <- list()
    res <- eval(bquote(lake_walk(tbl, function(p) pieces[[length(pieces) + 1L]] <<- p, filter = .(case$filter))))
    expect_null(res)
    whole <- eval(bquote(lake_read(tbl, filter = .(case$filter))))
    expect_identical(do.call(rbind, pieces), whole)
    expect_true(all(vapply(pieces, nrow, 0L) > 0L))
    expect_lte(length(pieces), nrow(lake_files(tbl)))
  }
  expect_error(lake_walk(lake_open(fixture_table("zl-basic")), "print"), class = "zulake_error_argument")
  # A filter no row matches calls FUN on nothing.
  called <- FALSE
  lake_walk(lake_open(fixture_table("zl-basic")), function(p) called <<- TRUE, filter = id < -1)
  expect_false(called)
})

test_that("lake_count(footers = TRUE) counts the rows of files without numRecords from their footers", {
  for (table in c("simple_table", "delta-0.8.0-partitioned", "delta-0.8.0-null-partition")) {
    for (v in oracle_versions(table)) {
      tbl <- lake_open(fixture_table(table), version = v)
      expect_warning(expect_identical(lake_count(tbl), NA_real_), class = "zulake_warning_count_unknown")
      rows <- oracle_field(table, v, c("read", "num_rows"))
      expect_identical(lake_count(tbl, footers = TRUE), as.numeric(rows))
    }
  }
  # With numRecords everywhere, footers are not read.
  tbl <- lake_open(fixture_table("zl-basic"))
  env <- new.env()
  tbl$storage <- remote_storage(tbl$storage, env)
  expect_identical(lake_count(tbl, footers = TRUE), lake_count(tbl))
  expect_length(env$calls, 0L)
  for (bad in list(NA, "yes", c(TRUE, FALSE), 1)) {
    expect_error(lake_count(tbl, footers = bad), class = "zulake_error_argument")
  }
})

test_that("a backend without local paths downloads each data file once per session", {
  path <- local_fixture_copy("zl-partitioned")
  tbl <- lake_open(path)
  direct <- lake_read(tbl)
  env <- new.env()
  tbl$storage <- remote_storage(tbl$storage, env)
  expect_identical(lake_read(tbl), direct)
  gets <- env$calls[startsWith(env$calls, "get ")]
  expect_setequal(sub("^get ", "", gets), percent_decode(lake_files(tbl)$path))
  expect_identical(anyDuplicated(gets), 0L)
  expect_identical(lake_read(tbl, filter = p_int == 1), direct[direct$p_int %in% 1, , drop = FALSE], ignore_attr = TRUE)
  expect_identical(env$calls[startsWith(env$calls, "get ")], gets)
  # A download of another size than the log's is refused.
  tbl2 <- lake_open(local_fixture_copy("zl-basic"))
  env2 <- new.env()
  storage <- remote_storage(tbl2$storage, env2)
  get <- storage$get
  storage$get <- function(path) get(path)[-1L]
  tbl2$storage <- storage
  expect_error(lake_read(tbl2), class = "zulake_error_storage")
  expect_error(lake_count(tbl2, footers = TRUE), NA)
})

test_that("lake_read() arguments are checked", {
  tbl <- lake_open(fixture_table("zl-basic"))
  expect_error(lake_read("x"), class = "zulake_error_argument")
  for (bad in list(1, NA_character_, c("id", NA), "nope", c("id", "id"), list("id"))) {
    expect_error(lake_read(tbl, columns = bad), class = "zulake_error_argument")
  }
  for (bad in list(NA, "int", 1)) {
    expect_error(lake_read(tbl, int64 = bad), class = "zulake_error_argument")
  }
  expect_identical(names(lake_read(tbl, columns = c("x", "id"))), c("x", "id"))
  zero <- lake_read(tbl, columns = character())
  expect_identical(dim(zero), c(as.integer(lake_count(tbl)), 0L))
  expect_error(lake_read(tbl, filter = "id > 1"), class = "zulake_error_filter")
  expect_error(lake_read(tbl, filter = id + 1), class = "zulake_error_filter")
  expect_error(lake_read(tbl, filter = id == no_such_value_anywhere), class = "zulake_error_filter")
  expect_error(lake_read(tbl, filter = id == 1/3), class = "zulake_error_filter")
  expect_error(lake_read(tbl, filter = id > "1.2.3"), class = "zulake_error_filter")
})

test_that("a read with no file or no matching row has the columns and types of a full read", {
  for (case in read_cases()) {
    if (case$table %in% c("zl-types", "zl-catalog-managed")) next
    tbl <- case_snapshot(case)
    # qio warns that it read zl-int32-min's -2^31 as NA (#79).
    full <- if (case$table == "zl-int32-min") suppressWarnings(lake_read(tbl)) else lake_read(tbl)
    none <- lake_read(tbl, filter = FALSE)
    expect_identical(nrow(none), 0L)
    expect_identical(lapply(none, class), lapply(full, class), label = paste(case$table, case$version))
    expect_identical(lapply(none, typeof), lapply(full, typeof), label = paste(case$table, case$version))
  }
  tbl <- lake_open(fixture_table("zl-types"))
  full <- suppressWarnings(lake_read(tbl))
  none <- suppressWarnings(lake_read(tbl, filter = s == "no such value"))
  expect_identical(lapply(none, class), lapply(full, class))
  path <- hand_table(c(protocol_line(), metadata_line(c(id = "long", p = "integer", d = "date"), partition = "p")))
  r <- lake_read(lake_open(path))
  expect_identical(dim(r), c(0L, 3L))
  expect_s3_class(r$d, "Date")
})

test_that("decimal precision straddles 15 in reads and in statistics", {
  path <- local_fixture_copy("zl-basic")
  files <- lake_files(lake_open(path), stats = FALSE)
  write_commit(path, 5, c(
    metadata_line(c(id = "long", label = "string", x = "double", d14 = "decimal(14,2)", d15 = "decimal(15,2)",
                    d16 = "decimal(16,2)"), partition = c("d14", "d15", "d16")),
    vapply(files$path, function(p) remove_line(p), ""),
    add_line(files$path[1L], partition = list(d14 = "123456789012.34", d15 = "1234567890123.45", d16 = "12345678901234.56"),
             size = files$size_bytes[1L])
  ))
  tbl <- lake_open(path)
  got <- collect_warnings(lake_read(tbl))
  expect_identical(vapply(got$warnings, function(w) w$column, ""), "d16")
  expect_match(got$warnings[[1L]]$reason, "decimal precision 16 > 15", fixed = TRUE)
  expect_identical(unique(got$value$d14), 123456789012.34)
  expect_identical(unique(got$value$d15), 1234567890123.45)
  expect_identical(sprintf("%.2f", unique(got$value$d15)), "1234567890123.45")
  expect_error(lake_read(tbl, columns = "d16"), class = "zulake_error_column_unreadable")
  # Statistics: a bound up to precision 15, never past it.
  stats <- '{\\"numRecords\\":1,\\"minValues\\":{\\"d\\":1.25},\\"maxValues\\":{\\"d\\":2.50},\\"nullCount\\":{\\"d\\":0}}'
  for (p in c(14, 15, 16)) {
    tbl <- lake_open(raw_table(c(raw_header(c(d = sprintf("decimal(%d,2)", p))), raw_add("a.parquet", stats = stats))))
    expect_identical(nrow(lake_files(tbl, filter = d > 3)), if (p <= 15) 0L else 1L, label = paste("precision", p))
  }
})

test_that("data files at absolute paths and file: URIs are read; other schemes and missing files are classed errors", {
  path <- local_fixture_copy("zl-basic")
  tbl <- lake_open(path)
  full <- lake_read(tbl)
  files <- lake_files(tbl, stats = FALSE)
  dir <- withr::local_tempdir()
  moved <- file.path(dir, c("moved.parquet", "moved file %.parquet"))
  stopifnot(file.copy(file.path(path, files$path[1:2]), moved))
  abs <- normalizePath(moved, winslash = "/")
  enc <- gsub("%", "%25", abs[2L], fixed = TRUE)
  enc <- gsub(" ", "%20", enc, fixed = TRUE)
  uri <- if (startsWith(enc, "/")) paste0("file://", enc) else paste0("file:///", enc)
  write_commit(path, 5, c(
    remove_line(files$path[1L]),
    add_line(abs[1L], size = files$size_bytes[1L]),
    remove_line(files$path[2L]),
    add_line(uri, size = files$size_bytes[2L])
  ))
  unlink(file.path(path, files$path[1:2]))
  expect_identical(nrow(lake_read(lake_open(path))), nrow(full))
  write_commit(path, 6, c(add_line("abfss://lake@account.dfs.core.windows.net/t/x.parquet")))
  expect_error(lake_read(lake_open(path)), class = "zulake_error_uri")
  write_commit(path, 7, c(remove_line("abfss://lake@account.dfs.core.windows.net/t/x.parquet"),
                          add_line("no-such-file.parquet")))
  expect_error(lake_read(lake_open(path)), class = "zulake_error_storage")
  expect_error(lake_count(lake_open(path), footers = TRUE), class = "zulake_error_storage")
  gone <- file.path(normalizePath(withr::local_tempdir(), winslash = "/"), "gone.parquet")
  write_commit(path, 8, c(remove_line("no-such-file.parquet"), add_line(gone)))
  expect_error(lake_read(lake_open(path)), class = "zulake_error_storage")
  # A directory named in the log is not a data file.
  folder <- normalizePath(withr::local_tempdir(), winslash = "/")
  write_commit(path, 9, c(remove_line(gone), add_line(folder)))
  expect_error(lake_read(lake_open(path)), class = "zulake_error_storage")
})

test_that("a Windows drive path is absolute, as are a root path and a URI; a table-relative path is not", {
  for (p in c("C:/data/part-0.parquet", "c:\\data\\part-0.parquet", "/data/part-0.parquet", "file:///data/x.parquet",
              "file:/data/x.parquet", "abfss://lake@account.dfs.core.windows.net/t/x.parquet")) {
    expect_true(is_absolute_path(p), label = p)
  }
  for (p in c("part-0.parquet", "year=2024/part-0.parquet", "p%3A1/part-0.parquet")) {
    expect_false(is_absolute_path(p), label = p)
  }
  expect_identical(absolute_local_path("C:/data/part-0.parquet"), "C:/data/part-0.parquet")
  expect_identical(absolute_local_path("file:///C:/data/a%20b.parquet"), "C:/data/a b.parquet")
  expect_identical(absolute_local_path("file:///data/a%20b.parquet"), "/data/a b.parquet")
  expect_error(absolute_local_path("s3://bucket/x.parquet"), class = "zulake_error_uri")
})

test_that("a column two files store as different types is a corrupt log", {
  path <- local_fixture_copy("zl-basic")
  tbl <- lake_open(path)
  qio::write_parquet(data.frame(id = c(100, 101), label = c("p", "q"), x = 1:2), file.path(path, "other.parquet"))
  write_commit(path, 5, add_line("other.parquet", size = file.size(file.path(path, "other.parquet"))))
  err <- tryCatch(lake_read(lake_open(path)), error = identity)
  expect_s3_class(err, "zulake_error_corrupt_log")
  expect_identical(err$column, "x")
  # Each file alone reads.
  expect_identical(nrow(lake_read(lake_open(path), filter = id >= 100)), 2L)
})

test_that("a cached download deleted from disk is downloaded again, not read as missing (#63)", {
  local_empty_download_cache()
  tbl <- lake_open(local_fixture_copy("zl-partitioned"))
  direct <- lake_read(tbl)
  env <- new.env()
  tbl$storage <- remote_storage(tbl$storage, env)
  expect_identical(lake_read(tbl), direct)
  gets <- env$calls[startsWith(env$calls, "get ")]
  cache <- get("cache_env", envir = asNamespace("zulake"))
  cached <- vapply(cache$files, function(e) e$file, "", USE.NAMES = FALSE)
  expect_length(cached, length(gets))
  # The session's temporary files go (a tempdir cleaner, the user): the
  # next read downloads each file again and returns the same rows.
  unlink(cached)
  expect_identical(lake_read(tbl), direct)
  expect_identical(env$calls[startsWith(env$calls, "get ")], c(gets, gets))
  expect_true(all(file.exists(vapply(cache$files, function(e) e$file, "", USE.NAMES = FALSE))))
  # Only one of them gone: only that one again.
  unlink(vapply(cache$files, function(e) e$file, "", USE.NAMES = FALSE)[1L])
  expect_identical(lake_read(tbl), direct)
  expect_length(env$calls[startsWith(env$calls, "get ")], 2L * length(gets) + 1L)
})

test_that("a relative log path with an empty, \".\" or \"..\" segment is a corrupt log, before any file is read (#66)", {
  src <- fixture_table("zl-basic")
  files <- lake_files(lake_open(src), stats = FALSE)
  bad <- c("../x.parquet", "a/../../x.parquet", "./a.parquet", "a/./b.parquet", "a//b.parquet", "a/",
           "%2E%2E/x.parquet", "a/%2e%2e/%2E%2E/x.parquet", "..", ".")
  for (p in bad) {
    path <- file.path(withr::local_tempdir(), "t")
    for (f in files$path) {
      dir.create(dirname(file.path(path, f)), recursive = TRUE, showWarnings = FALSE)
      file.copy(file.path(src, f), file.path(path, f))
    }
    # The good files first, so a check made file by file would read them.
    write_commit(path, 0, c(protocol_line(), metadata_line(c(id = "long", label = "string", x = "double")),
                            vapply(files$path, add_line, "", USE.NAMES = FALSE), add_line(p)))
    tbl <- lake_open(path)
    rec <- new.env()
    tbl$storage <- recording_storage(tbl$storage, rec)
    for (call in list(quote(lake_read(tbl)), quote(lake_walk(tbl, identity)), quote(lake_count(tbl, footers = TRUE)))) {
      err <- tryCatch(eval(call), error = identity)
      expect_s3_class(err, "zulake_error_corrupt_log")
      expect_identical(err$file, p, label = p)
      expect_length(rec$calls, 0L)
    }
  }
  # A name with dots that is not "." or "..", and an encoded "/" inside a
  # segment, are names like any other.
  for (p in c("..a.parquet", "a..b/c.parquet", "...")) {
    expect_false(zulake:::bad_relative_path(p), label = p)
  }
})

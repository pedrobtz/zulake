# The R type of every column read, against the schema (design section 7):
# partition columns read as data columns of their type (#118), data files
# whose Parquet types disagree with the schema (#119), void columns (#133),
# and a flat column whose path a nested one also renders (#116).

# ---- partition columns read as data columns (#118) ---------------------------

test_that("each partition type reads identical() to a data column holding the same values, and as deltalake reads it", {
  # zl-partition-types holds every partition type twice, as p_<type> and as
  # d_<type>; version 1 adds partition texts deltalake reads through a float
  # (16777217, 1e39) and to the microsecond (nine fraction digits).
  types <- c("byte", "short", "integer", "long", "float", "double", "decimal", "string", "boolean", "date",
             "timestamp", "timestamp_ntz", "binary")
  for (version in 0:1) {
    tbl <- lake_open(fixture_table("zl-partition-types"), version = version)
    got <- collect_warnings(lake_read(tbl))
    r <- got$value
    for (t in types) {
      expect_identical(r[[paste0("p_", t)]], r[[paste0("d_", t)]], label = paste(t, "at version", version))
    }
    expect_read_oracle(r, "zl-partition-types", version)
    # An integer of -2^31 reads as NA in both, each with qio's warning text.
    texts <- vapply(got$warnings, conditionMessage, "")
    expect_true(all(grepl("were coerced to NA because R's integer type reserves -2147483648", texts)))
    expect_setequal(sub(".*column '([^']+)'.*", "\\1", texts), c("p_integer", "d_integer"))
  }
  r <- suppressWarnings(lake_read(tbl))
  expect_identical(r$p_float[r$id %in% 0:4], c(1.100000023841858, 3.4028234663852886e+38, NA, 16777216, Inf))
  expect_identical(r$p_binary[r$id %in% 0:2], list(charToRaw("abc"), as.raw(1:2), NULL))
  expect_identical(format(r$p_timestamp[r$id %in% 3:4], "%H:%M:%OS6"), c("10:00:00.123456", "10:00:00.999999"))
  # lake_files() keeps the log's text for a binary partition, and an exact
  # double for an integer one; floats are rounded there too, for pruning.
  files <- lake_files(tbl, stats = FALSE)
  pv <- files$partition[order(files$path)]
  expect_identical(vapply(pv, function(p) p$p_binary, ""), c("abc", "\001\002", NA, "abc", "abc"))
  expect_identical(vapply(pv, function(p) p$p_integer, 0), c(-2147483648, 2147483647, NA, -2147483648, -2147483648))
  expect_identical(vapply(pv, function(p) p$p_float, 0), c(1.100000023841858, 3.4028234663852886e+38, NA, 16777216, Inf))
})

test_that("filters on partition columns of every type equal subset() of the read", {
  tbl <- lake_open(fixture_table("zl-partition-types"))
  full <- suppressWarnings(lake_read(tbl))
  for (col in grep("^[pd]_", names(full), value = TRUE)) {
    x <- full[[col]]
    sym <- as.symbol(col)
    exprs <- list(bquote(is.na(.(sym))), bquote(!is.na(.(sym))))
    if (!is.list(x)) {
      vals <- x[!is.na(x)]
      v <- if (is.numeric(vals) && !inherits(vals, c("Date", "POSIXct"))) vals[which.min(abs(vals))] else vals[1L]
      exprs <- c(exprs, list(
        bquote(.(sym) == .(v)), bquote(.(sym) != .(v)), bquote(.(sym) < .(v)), bquote(.(sym) >= .(v)),
        bquote(.(sym) %in% .(c(v, v)))
      ))
    }
    for (e in exprs) {
      got <- suppressWarnings(eval(bquote(lake_read(tbl, filter = .(e)))))
      # On a list column is.na() is TRUE for NULL, as the null count counts
      # it (design section 6), where base R's is FALSE.
      want <- if (is.list(x)) {
        keep <- vapply(x, is.null, NA)
        if (identical(e[[1L]], as.name("!"))) keep <- !keep
        new_data_frame(lapply(full, function(col) col[keep]), sum(keep))
      } else {
        r_subset(full, e)
      }
      expect_identical(got[order(got$id), ], want[order(want$id), ], label = deparse(e), ignore_attr = "row.names")
    }
  }
})

test_that("float partition values round through single precision, as deltalake reads them (#118)", {
  # deltalake 1.7.0 reads these texts as these floats (fixture
  # zl-partition-types, and the bug hunt's pt_float).
  parse <- function(x) zulake:::parse_partition_values(x, "float", "double", "p")
  expect_identical(parse(c("1.1", "16777217", "1e39", "-1e39", "3.4028235e38")),
                   c(1.100000023841858, 16777216, Inf, -Inf, 3.4028234663852886e+38))
  expect_identical(parse(c("-0", "NaN", "inf", NA)), c(-0, NaN, Inf, NA))
  expect_identical(1 / parse("-0"), -Inf)
  # Below the smallest float, to zero; a double partition is not rounded.
  expect_identical(parse("1e-50"), 0)
  expect_identical(zulake:::parse_partition_values("1.1", "double", "double", "p"), 1.1)
})

test_that("time text past the microsecond is truncated, and a filter literal that needs the digits is an error (#118)", {
  parse <- function(x) zulake:::parse_time_text(x)
  expect_identical(parse("2024-01-05 10:00:00.123456789"), parse("2024-01-05 10:00:00.123456"))
  expect_identical(parse("2024-01-05 10:00:00.9999999"), parse("2024-01-05 10:00:00.999999"))
  expect_identical(parse("1969-12-31 23:59:59.9999999"), parse("1969-12-31 23:59:59.999999"))
  path <- hand_table(c(
    protocol_line(), metadata_line(c(id = "long", ts = "timestamp"), partition = "ts"),
    add_line("a.parquet", list(ts = "2024-01-05 10:00:00.123456789"))
  ))
  write_parquet_long(data.frame(id = 1), file.path(path, "a.parquet"))
  tbl <- lake_open(path)
  expect_identical(nrow(lake_read(tbl, filter = ts == "2024-01-05 10:00:00.123456000")), 1L)
  err <- tryCatch(lake_read(tbl, filter = ts < "2024-01-05 10:00:00.1234567"), error = identity)
  expect_s3_class(err, "zulake_error_filter")
  expect_match(conditionMessage(err), "microsecond", fixed = TRUE)
})

# ---- data files whose Parquet type is not the schema's (#119) -----------------

test_that("a data file whose column type disagrees with the schema is a corrupt log naming the file and the column", {
  cases <- list(
    "data-type-string-for-long" = list(column = "s", type = "long", physical = "BYTE_ARRAY", other = c("i8", "f64")),
    "data-type-long-for-integer" = list(column = "id", type = "integer", physical = "INT64", other = c("label", "x"))
  )
  for (name in names(cases)) {
    case <- cases[[name]]
    path <- fixture_table(name, "hostile")
    tbl <- lake_open(path)
    err <- tryCatch(suppressWarnings(lake_read(tbl)), error = identity)
    expect_s3_class(err, "zulake_error_corrupt_log")
    expect_identical(err$column, case$column, label = name)
    expect_identical(err$type, case$type, label = name)
    expect_identical(err$physical_type, case$physical, label = name)
    expect_true(err$file %in% lake_files(tbl, stats = FALSE)$path, label = name)
    expect_match(conditionMessage(err), err$file, fixed = TRUE)
    expect_error(suppressWarnings(lake_walk(tbl, function(p) stop("no piece expected"))), class = "zulake_error_corrupt_log")
    # Only the columns read are checked.
    expect_identical(names(lake_read(tbl, columns = case$other)), case$other)
  }
  # deltalake 1.7.0 refuses the strings; it reads the INT64 values, which
  # fit, through a cast zulake does not make (design section 7).
  expect_false(is.null(hostile_refusal("data-type-string-for-long")))
  expect_null(hostile_refusal("data-type-long-for-integer"))
})

test_that("INT32 files of a long column widen to the long mapping, as deltalake upcasts them", {
  tbl <- lake_open(fixture_table("zl-int32-in-long"))
  r <- lake_read(tbl)
  expect_type(r$x, "double")
  expect_read_oracle(r, "zl-int32-in-long", 1)
  expect_read_oracle(lake_read(lake_open(fixture_table("zl-int32-in-long"), version = 0)), "zl-int32-in-long", 0)
  expect_identical(nrow(lake_read(tbl, filter = x == 2147483647)), 1L)
  expect_identical(lake_read(tbl, filter = is.na(x))$id, 3)
  if (requireNamespace("bit64", quietly = TRUE)) {
    r64 <- lake_read(tbl, int64 = "integer64")
    expect_s3_class(r64$x, "integer64")
    expect_read_oracle(r64, "zl-int32-in-long", 1, int64 = "integer64")
  }
})

test_that("which Parquet types each Delta type reads, widened or refused", {
  ok <- zulake:::parquet_type_fit
  t <- function(type, physical, logical = NA, details = NA) ok(type, physical, logical, details)
  int <- function(bits, signed = "true") sprintf("bit_width=%d, signed=%s", bits, signed)
  # Read as written.
  expect_identical(t("byte", "INT32", "INTEGER", int(8)), "read")
  expect_identical(t("short", "INT32", "INTEGER", int(8)), "read")
  expect_identical(t("short", "INT32", "INTEGER", int(16)), "read")
  expect_identical(t("integer", "INT32"), "read")
  expect_identical(t("integer", "INT32", "INTEGER", int(16)), "read")
  expect_identical(t("long", "INT64"), "read")
  expect_identical(t("long", "INT64", "INTEGER", int(64)), "read")
  expect_identical(t("float", "FLOAT"), "read")
  expect_identical(t("double", "DOUBLE"), "read")
  expect_identical(t("double", "FLOAT"), "read")
  expect_identical(t("string", "BYTE_ARRAY", "STRING"), "read")
  expect_identical(t("binary", "BYTE_ARRAY"), "read")
  expect_identical(t("binary", "FIXED_LEN_BYTE_ARRAY"), "read")
  expect_identical(t("boolean", "BOOLEAN"), "read")
  expect_identical(t("date", "INT32", "DATE"), "read")
  for (unit in c("MILLIS", "MICROS", "NANOS")) {
    for (utc in c("true", "false")) {
      d <- sprintf("unit=%s, adjusted_to_utc=%s", unit, utc)
      expect_identical(t("timestamp", "INT64", "TIMESTAMP", d), "read")
      expect_identical(t("timestamp_ntz", "INT64", "TIMESTAMP", d), "read")
    }
  }
  expect_identical(t("timestamp", "INT96"), "read")
  expect_identical(t("decimal(10,2)", "INT64", "DECIMAL", "precision=10, scale=2"), "read")
  expect_identical(t("decimal(10,2)", "INT32", "DECIMAL", "precision=5, scale=2"), "read")
  expect_identical(t("decimal(10,2)", "FIXED_LEN_BYTE_ARRAY", "DECIMAL", "precision=9, scale=2"), "read")
  # Widened to the long mapping.
  expect_identical(t("long", "INT32"), "widen")
  expect_identical(t("long", "INT32", "INTEGER", int(8)), "widen")
  expect_identical(t("long", "INT32", "INTEGER", int(32)), "widen")
  # Refused.
  refused <- list(
    c("byte", "INT32"), c("byte", "INT32", "INTEGER", int(16)), c("short", "INT32"),
    c("integer", "INT64"), c("integer", "INT32", "INTEGER", int(32, "false")), c("integer", "INT32", "DATE"),
    c("long", "BYTE_ARRAY", "STRING"), c("long", "DOUBLE"), c("long", "INT64", "INTEGER", int(64, "false")),
    c("long", "INT64", "TIMESTAMP", "unit=MICROS, adjusted_to_utc=true"),
    c("float", "DOUBLE"), c("float", "INT32"), c("double", "INT32"), c("double", "INT64", "DECIMAL", "precision=10, scale=2"),
    c("string", "BYTE_ARRAY"), c("string", "INT32"), c("binary", "BYTE_ARRAY", "STRING"),
    c("boolean", "INT32"), c("date", "INT32"), c("date", "INT64", "TIMESTAMP", "unit=MICROS, adjusted_to_utc=true"),
    c("timestamp", "INT64"), c("timestamp", "INT32", "DATE"), c("timestamp_ntz", "INT96"),
    c("decimal(10,2)", "INT64", "DECIMAL", "precision=10, scale=3"),
    c("decimal(10,2)", "INT64", "DECIMAL", "precision=12, scale=2"),
    c("decimal(10,2)", "DOUBLE"), c("decimal(10,2)", "INT64")
  )
  for (r in refused) {
    r <- c(r, rep(NA, 4L - length(r)))
    expect_identical(t(r[1L], r[2L], r[3L], r[4L]), "refuse", label = paste(r, collapse = " "))
  }
})

test_that("a hand-written table per mismatch is refused when the column is read, and read where it widens", {
  here <- environment()
  write_table <- function(type, value) {
    path <- hand_table(c(protocol_line(3L, 7L, "timestampNtz", "timestampNtz"),
                         metadata_line(c(id = "long", x = type)), add_line("a.parquet")), env = here)
    df <- data.frame(id = 1)
    df[["x"]] <- value
    write_parquet_long(df, file.path(path, "a.parquet"))
    lake_open(path)
  }
  refused <- list(
    long = "a", integer = 1.5, short = 1L, double = 1L, float = 1.5, string = list(as.raw(1)),
    binary = "a", boolean = 1L, date = 1L, timestamp = as.Date("2024-01-05")
  )
  for (type in names(refused)) {
    tbl <- write_table(type, refused[[type]])
    err <- tryCatch(lake_read(tbl), error = identity)
    expect_s3_class(err, "zulake_error_corrupt_log")
    expect_identical(err$column, "x", label = type)
    expect_identical(err$file, "a.parquet", label = type)
    expect_identical(lake_read(tbl, columns = "id")$id, 1, label = type)
  }
  tbl <- write_table("long", 7L)
  expect_identical(lake_read(tbl)$x, 7)
  tbl <- write_table("timestamp_ntz", .POSIXct(0, tz = "UTC"))
  expect_identical(as.numeric(lake_read(tbl)$x), 0)
})

# ---- void columns (#133) -------------------------------------------------------

test_that("a void column reads as an all-NA logical column, as deltalake reads it", {
  tbl <- lake_open(fixture_table("zl-void"))
  expect_identical(lake_schema(tbl)$type[lake_schema(tbl)$name == "v"], "void")
  got <- collect_warnings(lake_read(tbl))
  expect_identical(vapply(got$warnings, function(w) w$column, ""), "st")
  r <- got$value
  expect_identical(r$v, rep(NA, 3L))
  expect_read_oracle(r, "zl-void", 0, skipped = "st")
  expect_identical(lake_read(tbl, columns = "v")$v, rep(NA, 3L))
  expect_identical(sort(lake_read(tbl, columns = "id", filter = is.na(v))$id), c(1, 2, 3))
  expect_identical(nrow(lake_read(tbl, columns = "id", filter = !is.na(v))), 0L)
  expect_identical(nrow(lake_files(tbl, filter = is.na(v))), nrow(lake_files(tbl)))
})

test_that("a void column is never read from a file, even one with a column of its name", {
  add <- json_line(list(add = list(
    path = "a.parquet", partitionValues = structure(list(), names = character()), size = 100,
    modificationTime = 0, dataChange = TRUE, stats = "{\"numRecords\":2,\"nullCount\":{\"v\":0}}"
  )))
  path <- hand_table(c(protocol_line(), metadata_line(c(id = "long", v = "void")), add))
  write_parquet_long(data.frame(id = c(1, 2), v = c(5, 6)), file.path(path, "a.parquet"))
  tbl <- lake_open(path)
  expect_identical(lake_read(tbl)$v, c(NA, NA))
  # A null count the writer should not have recorded never prunes.
  expect_identical(nrow(lake_read(tbl, filter = is.na(v))), 2L)
})

test_that("a void partition column accepts only a null value", {
  lines <- c(protocol_line(), metadata_line(c(id = "long", v = "void"), partition = "v"),
             add_line("a.parquet", list(v = NULL)), add_line("b.parquet", list(v = "")))
  path <- hand_table(lines)
  for (f in c("a.parquet", "b.parquet")) write_parquet_long(data.frame(id = 1), file.path(path, f))
  tbl <- lake_open(path)
  expect_identical(lake_read(tbl)$v, c(NA, NA))
  expect_identical(nrow(lake_read(tbl, filter = is.na(v))), 2L)
  lines[4L] <- add_line("b.parquet", list(v = "x"))
  err <- tryCatch(lake_open(hand_table(lines)), error = identity)
  expect_s3_class(err, "zulake_error_corrupt_log")
  expect_identical(err$column, "v")
})

# ---- a flat column a.b beside a struct a (#116) --------------------------------

test_that("a flat column whose path a struct field also renders is left out by name, and the rest reads", {
  tbl <- lake_open(fixture_table("zl-dotted-name"))
  got <- collect_warnings(lake_read(tbl))
  skipped <- Filter(function(w) inherits(w, "zulake_warning_column_skipped"), got$warnings)
  expect_length(got$warnings, length(skipped))
  reasons <- stats::setNames(vapply(skipped, function(w) w$reason, ""), vapply(skipped, function(w) w$column, ""))
  expect_setequal(names(reasons), c("a", "a.b"))
  expect_match(reasons[["a.b"]], "pedrobtz/qio#78", fixed = TRUE)
  expect_read_oracle(got$value, "zl-dotted-name", 0, skipped = c("a", "a.b"))
  err <- tryCatch(lake_read(tbl, columns = c("id", "a.b")), error = identity)
  expect_s3_class(err, "zulake_error_column_unreadable")
  expect_identical(err$column, "a.b")
  expect_error(lake_read(tbl, filter = `a.b` == 42), class = "zulake_error_column_unreadable")
  expect_identical(lake_read(tbl, columns = "id")$id, c(1, 2))
  # A schema that hides the struct (`a` typed `long`): the file's read plan
  # still finds the path taken.
  path <- local_fixture_copy("zl-dotted-name")
  file <- lake_files(tbl, stats = FALSE)
  write_commit(path, 1, c(metadata_line(c(id = "long", a = "long", "a.b" = "long")), remove_line(file$path)))
  write_commit(path, 2, add_line(file$path, size = file$size_bytes))
  err <- tryCatch(lake_read(lake_open(path), columns = "a.b"), error = identity)
  expect_s3_class(err, "zulake_error_column_unreadable")
  expect_match(err$reason, "pedrobtz/qio#78", fixed = TRUE)
  # A dotted name with no struct beside it reads.
  path <- hand_table(c(protocol_line(), metadata_line(c(id = "long", "a.b" = "long")), add_line("a.parquet")))
  write_parquet_long(data.frame(id = 1, "a.b" = 42, check.names = FALSE), file.path(path, "a.parquet"), c("id", "a.b"))
  expect_identical(lake_read(lake_open(path))[["a.b"]], 42)
})

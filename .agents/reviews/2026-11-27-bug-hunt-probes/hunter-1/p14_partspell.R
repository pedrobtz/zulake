source(file.path(Sys.getenv("W"), "common.R"))
# For a partitioned table by_<k>, replace the partition value of the file holding id==1 by `val`; then open, read, filter.
variant <- function(k, val) {
  src <- file.path(W, "t/parts", paste0("by_", k)); dst <- file.path(W, "t/variant"); unlink(dst, recursive = TRUE); dir.create(dst)
  file.copy(list.files(src, full.names = TRUE), dst, recursive = TRUE)
  f <- file.path(dst, "_delta_log/00000000000000000000.json"); l <- readLines(f, warn = FALSE)
  t0 <- lake_open(src); ff <- lake_files(t0, stats = FALSE)
  # find the file with id 1
  path1 <- NULL; lake_walk(t0, function(p) NULL)
  for (i in seq_len(nrow(ff))) { r <- qio::read_parquet(ff$uri[i]); if (1L %in% r$id) path1 <- ff$path[i] }
  hit <- which(grepl(path1, l, fixed = TRUE))
  l[hit] <- sub(sprintf('"partitionValues":\\{"%s":("[^"]*"|null)\\}', k), sprintf('"partitionValues":{"%s":%s}', k, val), l[hit])
  writeLines(l, f); dst
}
probe <- function(k, val, lits) {
  dst <- variant(k, val); t <- try1(lake_open(dst))
  if (is_err(t)) { cat(sprintf("%-5s %-34s open: ERR %s\n", k, val, substr(t$msg, 1, 90))); return(invisible()) }
  full <- try1(lake_read(t, columns = c("id", k)))
  if (is_err(full)) { cat(sprintf("%-5s %-34s read: ERR %s\n", k, val, substr(full$msg, 1, 90))); return(invisible()) }
  v1 <- full[[k]][full$id == 1]
  pv <- try1(lake_partitions(t)[[k]]); fv <- try1(lake_files(t)[[k]])
  cat(sprintf("%-5s %-34s row: %-28s partitions has: %s\n", k, val, paste(format(v1, digits = 17), class(v1)[1]), if (is_err(pv)) pv$msg else any(pv %in% v1 | (is.na(v1) & is.na(pv)))))
  for (lit in lits) for (op in c("==", "<=", ">=", "%in%")) {
    e <- as.call(list(as.symbol(op), as.symbol(k), lit))
    a <- try1(eval(bquote(lake_read(t, columns = c("id", .(k)), filter = .(e)))))
    r <- try1({ x <- eval(e, full, baseenv()); full[x %in% TRUE, , drop = FALSE] })
    if (is_err(a)) { cat("     ", deparse(e), "ERR", substr(a$msg, 1, 80), "\n"); next }
    if (!is_err(r) && !setequal(a$id, r$id)) cat("      DIFF", deparse(e), "got", paste(sort(a$id), collapse = ","), "subset", paste(sort(r$id), collapse = ","), "\n")
  }
}
for (v in c('"+1"', '"01"', '"1e0"', '"0x1"', '" 1"', '"1.0"', '"-0"', '"1 "', '"2147483648"', '"-2147483649"', '"1.5"', '"１"', '"1L"', '""', '1', 'true')) probe("pi", v, list(1, 1L, 0))
for (v in c('"+1"', '"01"', '"128"', '"-129"', '"1.0"', '"1e0"', '"-0"')) probe("pi8", v, list(1, 0))
for (v in c('"+12.30"', '"12.3"', '"12.300"', '"1.23e1"', '".5"', '"5."', '"012.30"', '"12.345"', '"123456789.00"', '"-0.00"', '"1E1"', '"Inf"', '"NaN"', '"12,30"')) probe("pdec", v, list(12.3, 0, 0.5, 5, 10, "12.30", 12.345))
for (v in c('"2024-1-31"', '"2024-01-31 00:00:00"', '"24-01-31"', '"2024-02-30"', '"+2024-01-31"', '"10000-01-01"', '"0000-01-01"', '"2024-01-31T00:00:00Z"', '"20240131"', '"19753"')) probe("pd", v, list(as.Date("2024-01-31"), "2024-01-31", 19753))
for (v in c('"2024-01-31 12:00:00"', '"2024-01-31T12:00:00Z"', '"2024-01-31T13:00:00+01:00"', '"2024-01-31 12:00:00.1234567"', '"2024-01-31 12:00:00.123456789"', '"2024-01-31 12:00"', '"2024-01-31"', '"2024-01-31 24:00:00"', '"2024-01-31 12:00:60"', '"2024-01-31T12:00:00.5-0530"', '"2024-01-31 12:00:00 UTC"', '"1706702400"', '"2024-01-31 12:00:00.9999995"', '"2024-01-31T12:00:00+01"', '"2024-1-31 1:00:00"')) probe("pts", v, list(as.POSIXct("2024-01-31 12:00:00", tz = "UTC"), "2024-01-31 12:00:00", "2024-01-31 12:00:00.123457"))
for (v in c('"2024-01-31 12:00:00"', '"2024-01-31T12:00:00Z"', '"2024-01-31T12:00:00"', '"2024-01-31 12:00:00+01:00"')) probe("ptn", v, list(as.POSIXct("2024-01-31 12:00:00", tz = "UTC"), "2024-01-31 12:00:00"))
for (v in c('"TRUE"', '"True"', '"1"', '"t"', '"yes"', '"false "', '"FALSE"', '"0"', 'true', '"tRuE"')) probe("pb", v, list(TRUE, FALSE, 1))
for (v in c('"+1"', '"007"', '"1e0"', '"1.0"', '"9007199254740992"', '"-9007199254740992"', '"9223372036854775808"', '" 1"', '"0x1"', '"-0"')) probe("pl", v, list(1, 7, 0, 2^53))
for (v in c('""', '" "', '"NULL"', '"__HIVE_DEFAULT_PARTITION__"', '"a\\u0000b"', '"\\ud83d\\ude00"', '"NA"', '"é"')) probe("ps", v, list("", " ", "NA", "__HIVE_DEFAULT_PARTITION__", "é"))

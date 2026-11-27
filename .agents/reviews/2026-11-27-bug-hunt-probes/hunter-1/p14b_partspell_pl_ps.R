source(file.path(Sys.getenv("W"), "common.R"))
# For a partitioned table by_<k>, replace the partition value of the file holding id==1 by `val`; then open, read, filter.
variant <- function(k, val) {
  src <- if (k == "pl") file.path(W, "t/by_pl2") else file.path(W, "t/parts", paste0("by_", k)); dst <- file.path(W, "t/variant"); unlink(dst, recursive = TRUE); dir.create(dst)
  file.copy(list.files(src, full.names = TRUE), dst, recursive = TRUE)
  f <- file.path(dst, "_delta_log/00000000000000000000.json"); l <- readLines(f, warn = FALSE)
  t0 <- lake_open(src); ff <- lake_files(t0, stats = FALSE, int64 = "integer64")
  # find the file with id 1
  path1 <- NULL
  for (i in seq_len(nrow(ff))) { r <- qio::read_parquet(ff$uri[i]); if (1L %in% r$id) path1 <- ff$path[i] }
  hit <- which(grepl(path1, l, fixed = TRUE))
  l[hit] <- sub(sprintf('"partitionValues":\\{"%s":("[^"]*"|null)\\}', k), sprintf('"partitionValues":{"%s":%s}', k, val), l[hit])
  writeLines(l, f); dst
}
probe <- function(k, val, lits) {
  dst <- variant(k, val); t <- try1(lake_open(dst))
  if (is_err(t)) { cat(sprintf("%-5s %-34s open: ERR %s\n", k, val, substr(t$msg, 1, 90))); return(invisible()) }
  full <- try1(lake_read(t, columns = c("id", k), int64 = "integer64"))
  if (is_err(full)) { cat(sprintf("%-5s %-34s read: ERR %s\n", k, val, substr(full$msg, 1, 90))); return(invisible()) }
  v1 <- full[[k]][full$id == 1]
  pv <- try1(lake_partitions(t, int64 = "integer64")[[k]]); fv <- try1(lake_files(t)[[k]])
  cat(sprintf("%-5s %-34s row: %-28s partitions has: %s\n", k, val, paste(format(v1, digits = 17), class(v1)[1]), if (is_err(pv)) pv$msg else any(pv %in% v1 | (is.na(v1) & is.na(pv)))))
  for (lit in lits) for (op in c("==", "<=", ">=", "%in%")) {
    e <- as.call(list(as.symbol(op), as.symbol(k), lit))
    a <- try1(eval(bquote(lake_read(t, columns = c("id", .(k)), filter = .(e), int64 = "integer64"))))
    r <- try1({ x <- eval(e, full, baseenv()); full[x %in% TRUE, , drop = FALSE] })
    if (is_err(a)) { cat("     ", deparse(e), "ERR", substr(a$msg, 1, 80), "\n"); next }
    if (!is_err(r) && !setequal(a$id, r$id)) cat("      DIFF", deparse(e), "got", paste(sort(a$id), collapse = ","), "subset", paste(sort(r$id), collapse = ","), "\n")
  }
}
for (v in c('"+1"', '"007"', '"1e0"', '"1.0"', '"9007199254740992"', '"-9007199254740992"', '"9223372036854775808"', '" 1"', '"0x1"', '"-0"')) probe("pl", v, list(1, 7, 0, 2^53))
for (v in c('""', '" "', '"NULL"', '"__HIVE_DEFAULT_PARTITION__"', '"a\\u0000b"', '"\\ud83d\\ude00"', '"NA"', '"é"')) probe("ps", v, list("", " ", "NA", "__HIVE_DEFAULT_PARTITION__", "é"))

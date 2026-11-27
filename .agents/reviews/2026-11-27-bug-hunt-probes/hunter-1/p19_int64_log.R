source(file.path(Sys.getenv("W"), "common.R")); suppressPackageStartupMessages(library(bit64))
mk <- function(field, val) {
  src <- file.path(FX, "zl-basic"); dst <- file.path(W, "t/i64log"); unlink(dst, recursive = TRUE); dir.create(dst)
  file.copy(list.files(src, full.names = TRUE), dst, recursive = TRUE)
  f <- file.path(dst, "_delta_log/00000000000000000000.json"); l <- readLines(f, warn = FALSE)
  pat <- switch(field, size = '"size":[0-9]+', modificationTime = '"modificationTime":[0-9]+', numRecords = '\\\\"numRecords\\\\":[0-9]+', min = '\\\\"minValues\\\\":\\{\\\\"id\\\\":[0-9]+', nullCount = '\\\\"nullCount\\\\":\\{\\\\"id\\\\":[0-9]+')
  rep <- switch(field, size = paste0('"size":', val), modificationTime = paste0('"modificationTime":', val), numRecords = paste0('\\\\\\\\"numRecords\\\\\\\\":', val), min = paste0('\\\\\\\\"minValues\\\\\\\\":{\\\\\\\\"id\\\\\\\\":', val), nullCount = paste0('\\\\\\\\"nullCount\\\\\\\\":{\\\\\\\\"id\\\\\\\\":', val))
  l2 <- sub(pat, rep, l); stopifnot(!identical(l, l2)); writeLines(l2, f); dst
}
if (FALSE) cat(readLines(file.path(FX, "zl-basic/_delta_log/00000000000000000000.json")), sep = "\n")
col <- c(size = "size_bytes", modificationTime = "modification_time", numRecords = "records", min = "min", nullCount = "null_count")
for (field in names(col)) for (val in c("9007199254740993", "9007199254740993.0", "9.007199254740993e15", "9007199254740992", "1e3", "1.0", "1.5", "-1", "1e19", "9223372036854775808", "-9223372036854775808", "12345678901234567890.5", "\"5\"", "null", "true", "0")) {
  if (field == "min" && val %in% c("\"5\"")) val <- "\\\\\\\\\"5\\\\\\\\\""
  t <- try1(lake_open(mk(field, val), version = 0))
  if (is_err(t)) { cat(sprintf("%-16s %-24s open ERR %s\n", field, val, substr(t$msg, 1, 100))); next }
  g <- function(m) { f <- try1(withCallingHandlers(lake_files(t, int64 = m), warning = function(w) { cat("      [warning]", substr(conditionMessage(w), 1, 90), "\n"); invokeRestart("muffleWarning") })); if (is_err(f)) paste("ERR", substr(f$msg, 1, 70)) else { v <- f[[col[[field]]]]; v <- if (is.data.frame(v)) v$id else if (is.list(v)) v[[1]]$id else v; paste(class(v)[1], if (inherits(v, "POSIXct")) sprintf("%.3f", as.numeric(v[1])) else format(v[1], digits = 17)) } }
  cnt <- try1(lake_count(t)); sm <- try1(lake_summary(t))
  cat(sprintf("%-16s %-24s double: %-45s integer64: %-40s count: %s\n", field, val, g("double"), g("integer64"), if (is_err(cnt)) paste("ERR", substr(cnt$msg, 1, 50)) else format(cnt, digits = 17)))
}

source(file.path(Sys.getenv("W"), "common.R"))
# (e) lake_partitions(filter) vs lake_files(filter)
for (nm in c("zl-partitioned", "zl-orders", "zl-inf-partitions", "delta-0.8.0-partitioned", "delta-2.2.0-partitioned-types", "delta-0.8.0-null-partition")) {
  t <- lake_open(file.path(FX, nm)); pc <- lake_partition_columns(t); fl <- lake_files(t); bad <- 0; n <- 0
  for (col in pc) for (v in unique(fl[[col]])) for (op in c("==", "!=", "<", ">=", "%in%")) {
    e <- if (is.na(v) && !is.nan(v)) call("is.na", as.symbol(col)) else as.call(list(as.symbol(op), as.symbol(col), v)); n <- n + 1
    p <- try1(eval(bquote(lake_partitions(t, filter = .(e))))); f <- try1(eval(bquote(lake_files(t, filter = .(e)))))
    if (is_err(p) || is_err(f)) { if (!(is_err(p) && is_err(f))) { bad <- bad + 1; cat("  err differ", deparse(e), "\n") }; next }
    key <- function(d) unique(do.call(paste, c(lapply(d[pc], function(x) if (is.numeric(x)) sprintf("%.17g", x) else as.character(x)), sep = "|")))
    if (!setequal(key(p), key(f))) { bad <- bad + 1; cat("  DIFF", nm, deparse(e), nrow(p), length(key(f)), "\n") }
    r <- suppressWarnings(eval(bquote(lake_read(t, filter = .(e))))); cnt <- sum(f$records); if (!is.na(cnt) && all(names(f) != "deletion_vector") && nrow(r) != cnt) { bad <- bad + 1; cat("  rows != records of kept files", deparse(e), nrow(r), cnt, "\n") }
  }
  cat(sprintf("%-34s partition filters=%d bad=%d\n", nm, n, bad))
}
# (f) a snapshot does not change when the log grows
src <- file.path(FX, "zl-basic"); dst <- file.path(W, "t/grow"); unlink(dst, recursive = TRUE); dir.create(dst); file.copy(list.files(src, full.names = TRUE), dst, recursive = TRUE)
last <- file.path(dst, "_delta_log", sprintf("%020d.json", 4)); hold <- file.path(W, "t/held.json"); file.rename(last, hold); crc <- sub("json$", "crc", last); if (file.exists(crc)) file.rename(crc, file.path(W, "t/held.crc"))
old <- lake_open(dst); before <- list(v = lake_version(old), f = lake_files(old), vs = lake_versions(old), lg = lake_log(old), rd = lake_read(old), p = utils::capture.output(print(old)), h = lake_history(old))
file.rename(hold, last)
after <- list(v = lake_version(old), f = lake_files(old), vs = lake_versions(old), lg = lake_log(old), rd = lake_read(old), p = utils::capture.output(print(old)), h = lake_history(old))
cat("old snapshot unchanged after a new commit:", identical(before, after), "\n")
new <- lake_load(old); cat("lake_load sees version", lake_version(new), "; old still", lake_version(old), "\n")
r <- try1(lake_load(old, version = 4)); cat("lake_load(old, version = 4):", if (is_err(r)) r$msg else lake_version(r), "\n")
r <- try1(lake_actions(old, 4)); cat("lake_actions(old, 4):", if (is_err(r)) substr(r$msg, 1, 100) else nrow(r), "\n")
r <- try1(lake_changes(old, 3, 4)); cat("lake_changes(old, 3, 4):", if (is_err(r)) substr(r$msg, 1, 100) else nrow(r), "\n")
r <- try1(lake_changes(new, 3, 4)); cat("lake_changes(new, 3, 4):", if (is_err(r)) substr(r$msg, 1, 100) else nrow(r), "\n")
r <- try1(lake_load(old, timestamp = Sys.time() + 1e6)); cat("lake_load(old, timestamp = future):", if (is_err(r)) r$msg else lake_version(r), "\n")
# data file removed after open
unlink(file.path(dst, lake_files(new)$path[1])); r <- try1(lake_read(new)); cat("read after a data file vanished:", if (is_err(r)) paste(r$cls, substr(r$msg, 1, 90)) else nrow(r), "\n")
r <- try1(lake_count(new)); cat("count:", if (is_err(r)) r$msg else r, "\n")
# saveRDS round trip
tf <- tempfile(fileext = ".rds"); saveRDS(old, tf); o2 <- readRDS(tf); r <- try1(lake_read(o2)); cat("read from saveRDS'd snapshot (local):", if (is_err(r)) substr(r$msg, 1, 100) else nrow(r), "\n")
# modified snapshot object
o3 <- old; o3$version <- 99; cat("tampered version accessor:", lake_version(o3), "\n"); class(o3) <- "list"; r <- try1(lake_version(o3)); cat("unclassed:", if (is_err(r)) r$msg else r, "\n")

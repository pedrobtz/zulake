source(file.path(Sys.getenv("W"), "common.R"))
invisible(Sys.setlocale("LC_COLLATE", "C"))
# 1. generic filter fuzz on fixtures: every column, values drawn from the column itself, pruned vs stats-stripped vs subset
fuzz <- function(nm, int64 = "double") {
  src <- file.path(FX, nm); t <- lake_open(src); ns <- try1(lake_open(strip_stats(src, file.path(W, "t/fx_nostats"))))
  full <- suppressWarnings(lake_read(t, int64 = int64)); n <- 0; bad <- 0
  for (col in names(full)) { x <- full[[col]]; if (is.list(x)) next
    vals <- unique(x); vals <- vals[!is.na(vals)]; if (length(vals) > 6) vals <- vals[unique(round(seq(1, length(vals), length.out = 6)))]
    for (i in seq_along(vals)) { v <- vals[i]
      for (e in c(lapply(c("==", "!=", "<", "<=", ">", ">="), function(op) as.call(list(as.symbol(op), as.symbol(col), v))), list(call("%in%", as.symbol(col), vals[c(1, i)]), call("!", call("%in%", as.symbol(col), v)), call("is.na", as.symbol(col)), call("|", call("is.na", as.symbol(col)), call("==", as.symbol(col), v))))) {
        n <- n + 1
        a <- try1(eval(bquote(lake_read(t, filter = .(e), int64 = int64)))); r <- try1({ k <- eval(e, full, baseenv()); full[k %in% TRUE, , drop = FALSE] })
        b <- if (is_err(ns)) a else try1(eval(bquote(lake_read(ns, filter = .(e), int64 = int64))))
        ok <- (is_err(a) && is_err(b)) || (!is_err(a) && !is_err(b) && same_df(a, b) && (is_err(r) || same_df(a, r)))
        if (!ok) { bad <- bad + 1; if (bad <= 4) cat("   BAD", nm, paste(deparse(e, width.cutoff = 200), collapse = ""), "| pruned", if (is_err(a)) substr(a$msg, 1, 70) else nrow(a), "nostats", if (is_err(b)) substr(b$msg, 1, 50) else nrow(b), "subset", if (is_err(r)) substr(r$msg, 1, 50) else nrow(r), "\n") }
        fl <- try1(eval(bquote(lake_files(t, filter = .(e), int64 = int64)))); 
      } } }
  cat(sprintf("%-36s %-9s filters=%d bad=%d\n", nm, int64, n, bad))
}
for (nm in c("column_mapping", "table_with_column_mapping", "deletion_vectors", "table-with-dv-small", "table-with-dv-small-inline", "zl-orders", "zl-partitioned", "zl-inf-partitions", "delta-0.8.0-null-partition", "delta-0.8.0-partitioned", "delta-2.2.0-partitioned-types", "table_with_edge_timestamps", "zl-types", "zl-int32-min", "checkpoint-v2-table", "zl-checkpoint", "table_with_ict", "simple_table")) { r <- try1(fuzz(nm)); if (is_err(r)) cat(nm, "FUZZ ERR", r$msg, "\n") }
for (nm in c("zl-types", "zl-orders", "table-with-dv-small", "column_mapping")) { r <- try1(fuzz(nm, "integer64")); if (is_err(r)) cat(nm, "FUZZ ERR", r$msg, "\n") }

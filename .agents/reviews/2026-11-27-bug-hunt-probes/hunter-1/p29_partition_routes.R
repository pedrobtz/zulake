source(file.path(Sys.getenv("W"), "common.R"))
fmt <- function(x) if (is.null(x) || length(x) == 0) "NULL" else if (is.numeric(x) && !inherits(x, c("Date", "POSIXct"))) sprintf("%.17g", x) else as.character(x)
for (nm in c("zl-partitioned", "zl-orders", "zl-inf-partitions", "delta-0.8.0-partitioned", "delta-2.2.0-partitioned-types", "delta-0.8.0-null-partition")) {
  t <- lake_open(file.path(FX, nm)); pc <- lake_partition_columns(t); fl <- lake_files(t); bad <- 0; n <- 0; pa <- lake_partitions(t)
  # lake_files()$partition values agree with lake_partitions() and with the rows read
  keyf <- function(f) unique(vapply(f$partition, function(p) paste(vapply(pc, function(c) fmt(p[[c]]), ""), collapse = "|"), ""))
  keyp <- function(p) unique(do.call(paste, c(lapply(p[pc], function(x) vapply(seq_along(x), function(i) fmt(x[i]), "")), sep = "|")))
  if (!setequal(keyf(fl), keyp(pa))) { cat("  files partition != partitions:", paste(setdiff(keyf(fl), keyp(pa)), collapse = " ; "), "<>", paste(setdiff(keyp(pa), keyf(fl)), collapse = " ; "), "\n") }
  rd <- suppressWarnings(lake_read(t)); if (!setequal(keyp(unique(rd[pc])), keyp(pa))) cat("  read partition values != partitions:", paste(setdiff(keyp(unique(rd[pc])), keyp(pa)), collapse = ";"), "<>", paste(setdiff(keyp(pa), keyp(unique(rd[pc]))), collapse = ";"), "\n")
  cat("  classes partitions:", vapply(pa[pc], function(x) class(x)[1], ""), "| read:", vapply(rd[pc], function(x) class(x)[1], ""), "| files$partition:", vapply(pc, function(c) class(fl$partition[[1]][[c]])[1], ""), "\n")
  for (col in pc) for (v in unique(pa[[col]])) for (op in c("==", "!=", "<", ">=", "%in%")) {
    v <- pa[[col]][match(v, pa[[col]])]
    e <- if (is.na(v) && !is.nan(v)) call("is.na", as.symbol(col)) else as.call(list(as.symbol(op), as.symbol(col), v)); n <- n + 1
    p <- try1(eval(bquote(lake_partitions(t, filter = .(e))))); f <- try1(eval(bquote(lake_files(t, filter = .(e)))))
    if (is_err(p) || is_err(f)) { if (!(is_err(p) && is_err(f))) { bad <- bad + 1; cat("  err differ", deparse(e), "\n") }; next }
    if (!setequal(keyp(p), keyf(f))) { bad <- bad + 1; cat("  DIFF", nm, deparse(e), nrow(p), nrow(f), "\n") }
    r <- suppressWarnings(eval(bquote(lake_read(t, filter = .(e))))); cnt <- sum(f$num_records); if (!is.na(cnt) && nrow(r) != cnt) { bad <- bad + 1; cat("  rows != records of kept files", deparse(e), nrow(r), cnt, "\n") }
    want <- rd[eval(e, rd) %in% TRUE, , drop = FALSE]; if (nrow(want) != nrow(r)) { bad <- bad + 1; cat("  != subset", deparse(e), nrow(r), nrow(want), "\n") }
  }
  cat(sprintf("%-34s partition filters=%d bad=%d\n", nm, n, bad))
}

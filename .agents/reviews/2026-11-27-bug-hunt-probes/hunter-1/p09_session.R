source(file.path(Sys.getenv("W"), "common.R"))
if (nzchar(Sys.getenv("HOSTILE_OPTS"))) options(OutDec = ",", scipen = -5, digits = 3, stringsAsFactors = TRUE)
if (nzchar(Sys.getenv("WARN2"))) options(warn = 2)
out <- function(label, e) { r <- try1(e); cat(label, ":", if (is_err(r)) paste("ERR", r$msg) else rlang::hash(r), "\n") }
dig <- function(x) { if (is.data.frame(x)) x[] <- lapply(x, function(c) if (inherits(c, "POSIXct")) sprintf("%.6f", as.numeric(c)) else if (is.numeric(c) && !inherits(c, "integer64")) sprintf("%.17g", c) else if (is.list(c)) vapply(c, function(z) paste(utils::capture.output(dput(z)), collapse = ""), "") else as.character(c)); x }
tbl <- lake_open(file.path(W, "t/types"))
cols <- setdiff(lake_schema(tbl)$name, "i64")
es <- alist(a > 10, s > "a", s < "é", s == "é", s %in% c("Z", "é"), `a b` >= "b", f64 == 0.1, f64 > 1e5, f64 >= 123456789.12345679, f32 == 0.10000000149011612, dec == 12.3, dec == 0.1, dec15 == 1234567890.12345, dec15 == 0.00001, dec15 > 100000, dec > 1e5, a == 1e2,
  d == "2024-01-31", d == as.Date("2024-01-31"), ts == "2024-03-10 10:00:00", ts == as.POSIXct("2024-03-10 10:00:00", tz = "UTC"), ts > "2024-06-15 12:00:00.5", tn == "2024-03-10 02:30:00", tn >= "2024-11-03 05:30:00", s == 1e5, s == 100000, s == 0.1, s == 123456.7, s == TRUE,
  s == as.Date("2024-01-31"), s == as.POSIXct("2024-01-31 12:00:00", tz = "UTC"), toupper(s) == "BBB", as.character(f64) == "0.1", as.character(a) == "100", as.character(d) == "2024-01-31", as.character(ts) == "2024-03-10 10:00:00", substr(as.character(ts), 1, 10) == "2024-03-10", grepl("2024-03-10", tn), as.character(dec) == "12.3",
  i32 == 2147483647, i16 %in% c(32767, 1e2), a %in% c(1e2, 1e1), a > 1e5, f64 %in% c(0.1, 1e300), as.numeric(s) == 1, nchar(s) == 1, nchar(`a b`, "chars") == 3, a/3 > 10.5, round(f64, 1) == 0.3)
for (e in es) {
  r <- try1(eval(bquote(lake_read(tbl, columns = cols, filter = .(e)))))
  cat(sprintf("%-60s %s\n", paste(deparse(e, width.cutoff = 300), collapse = ""), if (is_err(r)) paste("ERR", substr(r$msg, 1, 100)) else paste(r$a, collapse = " ")))
  f <- try1(eval(bquote(lake_files(tbl, filter = .(e)))))
  if (!is_err(f)) cat("    files:", nrow(f), "\n")
}
full <- lake_read(tbl, columns = cols); cat("classes:", vapply(full, function(c) class(c)[1], ""), "\n"); cat("full:", rlang::hash(dig(full)), "\n")
ff <- suppressWarnings(lake_files(tbl)); cat("files classes:", vapply(ff, function(c) class(c)[1], ""), "\n"); cat("files:", rlang::hash(dig(ff)), "\n")
for (nm in c("zl-orders", "zl-partitioned", "table_with_ict", "zl-inf-partitions", "zl-domains", "deletion_vectors", "table_with_edge_timestamps", "zl-file-times")) {
  t2 <- lake_open(file.path(FX, nm))
  for (fn in c("lake_files", "lake_partitions", "lake_versions", "lake_history", "lake_schema", "lake_protocol", "lake_properties", "lake_metadata", "lake_transactions", "lake_removed", "lake_domains", "lake_checkpoints", "lake_summary", "lake_read", "lake_count", "lake_log")) {
    r <- try1(get(fn)(t2)); cat(nm, fn, if (is_err(r)) paste("ERR", r$msg) else rlang::hash(dig(r)), "\n")
  }
  r <- try1(lake_changes(t2, 0)); cat(nm, "changes", if (is_err(r)) paste("ERR", r$msg) else rlang::hash(dig(r)), "\n")
  r <- try1(lake_actions(t2, 0)); cat(nm, "actions", if (is_err(r)) paste("ERR", r$msg) else rlang::hash(dig(r)), "\n")
  cat(nm, "version by ts", lake_version(lake_load(t2, timestamp = lake_versions(t2)$timestamp[1])), "\n")
}
o <- lake_open(file.path(FX, "zl-orders"))
print(lake_read(o, filter = order_date >= "2025-01-08" & amount > 100.5))
print(lake_read(o, filter = order_date == as.Date(as.POSIXct("2025-01-08 23:30:00", tz = "UTC"))))

source(file.path(Sys.getenv("W"), "common.R")); source(file.path(W, "lits.R"))
invisible(Sys.setlocale("LC_COLLATE", "C"))
i64mode <- Sys.getenv("I64", "double")
for (k in c("pl", "pdec", "pts", "ptn", "pb", "ps", "pd", "pi", "pi8")) {
  tbl <- lake_open(file.path(W, "t/parts", paste0("by_", k)))
  full <- try1(lake_read(tbl, int64 = i64mode))
  if (is_err(full)) { cat(k, "FULL READ ERR:", full$msg, "\n"); next }
  cat("==", k, class(full[[k]]), "\n"); print(full[, c("id", k)], digits = 17)
  for (ln in names(lits)) for (e in mk_exprs(k, lits[[ln]])) {
    lab <- sprintf("%-40s [%s]", paste(deparse(e, width.cutoff = 200), collapse = ""), ln)
    a <- try1(eval(bquote(lake_read(tbl, filter = .(e), int64 = i64mode))))
    r <- try1({ x <- eval(e, full, baseenv()); full[x %in% TRUE, , drop = FALSE] })
    f <- try1(eval(bquote(lake_files(tbl, filter = .(e), int64 = i64mode))))
    if (is_err(a) != is_err(f)) cat("READ/FILES err differ", lab, "\n")
    if (is_err(a)) { if (!is_err(r) && nrow(r) > 0) cat("ERR-vs-R    ", lab, substr(a$msg, 1, 80), "| R rows", nrow(r), "\n"); next }
    if (!same_df(a, r)) cat("REF-DIFF    ", lab, paste(a$id, collapse = ","), "|", if (is_err(r)) paste("ERR", substr(r$msg, 1, 50)) else paste(r$id, collapse = ","), "\n")
    if (!is_err(f) && k != "pb" && nrow(f) != nrow(a)) cat("FILES-DIFF  ", lab, nrow(f), nrow(a), "\n")
  }
}

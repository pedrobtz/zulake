# Repro: a decimal partition value ".5" / "5." / "12.345" (scale 2) is accepted at open and read as a number,
# but the filter never matches it (file pruned / row dropped).
source(file.path(Sys.getenv("W"), "common.R"))
mk <- function(val) {
  src <- file.path(W, "t/parts/by_pdec"); dst <- file.path(W, "t/dec_variant"); unlink(dst, recursive = TRUE); dir.create(dst)
  file.copy(list.files(src, full.names = TRUE), dst, recursive = TRUE)
  f <- file.path(dst, "_delta_log/00000000000000000000.json"); l <- readLines(f, warn = FALSE)
  l <- sub('"partitionValues":{"pdec":"12.30"}', sprintf('"partitionValues":{"pdec":"%s"}', val), l, fixed = TRUE); writeLines(l, f); lake_open(dst)
}
for (val in c(".5", "5.", "-.5", "12.345", "0.5")) {
  t <- mk(val); full <- suppressMessages(lake_read(t, columns = c("id", "pdec"))); v <- full$pdec[full$id == 1]
  cat(sprintf("partition value %-8s reads as %s; lake_partitions: %s\n", dQuote(val, FALSE), format(v), paste(lake_partitions(t)$pdec, collapse = " ")))
  rd <- function(e) suppressMessages(eval(bquote(lake_read(t, columns = c("id", "pdec"), filter = .(e)))))$id
  for (e in list(bquote(pdec == .(v)), quote(pdec > -1000), quote(pdec <= 1000), bquote(pdec %in% .(v)), quote(!is.na(pdec)), quote(pdec != 77), quote(pdec + 0 > -1000))) {
    got <- rd(e); want <- full$id[eval(e, full) %in% TRUE]
    cat(sprintf("   %-22s filter ids: %-18s subset ids: %-18s files kept: %s %s\n", deparse(e), paste(sort(got), collapse = ","), paste(sort(want), collapse = ","),
      { f <- try1(eval(bquote(lake_files(t, filter = .(e))))); if (is_err(f)) "-" else nrow(f) }, if (setequal(got, want)) "" else "<-- WRONG"))
  }
}

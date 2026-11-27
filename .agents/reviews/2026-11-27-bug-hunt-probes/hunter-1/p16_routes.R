source(file.path(Sys.getenv("W"), "common.R"))
strip <- function(t) { t$downloads <- NULL; t$storage <- NULL; t$log <- NULL; t$last_checkpoint <- NULL; t }
for (nm in list.files(FX)) {
  t <- try1(lake_open(file.path(FX, nm))); if (is_err(t)) { cat(sprintf("%-40s open ERR %s\n", nm, substr(t$msg, 1, 80))); next }
  vs <- try1(lake_versions(t)); msgs <- character()
  cnt <- try1(lake_count(t)); rd <- try1(lake_read(t)); 
  if (!is_err(rd) && !is_err(cnt) && !identical(as.numeric(cnt), as.numeric(nrow(rd)))) msgs <- c(msgs, sprintf("count %s != nrow %s", format(cnt), nrow(rd)))
  if (is_err(rd)) msgs <- c(msgs, paste("read ERR", substr(rd$msg, 1, 60)))
  cf <- try1(lake_count(t, footers = TRUE)); if (!is_err(rd) && !is_err(cf) && !(cf == nrow(rd))) { dv <- try1(sum(lake_files(t)$deletion_vector_cardinality, na.rm = TRUE)); msgs <- c(msgs, sprintf("count(footers) %s != nrow %s", cf, nrow(rd))) }
  n <- 0; w <- try1(lake_walk(t, function(p) n <<- n + nrow(p))); if (!is_err(rd) && n != nrow(rd)) msgs <- c(msgs, "walk != read")
  f <- try1(lake_files(t)); if (!is_err(f) && !is_err(cnt) && !is.na(cnt)) { s <- sum(f$records) - sum(if ("deleted_records" %in% names(f)) f$deleted_records else 0, na.rm = TRUE); }
  sm <- try1(lake_summary(t))
  for (v in vs$version) {
    a <- try1(lake_open(file.path(FX, nm), version = v)); b <- try1(lake_load(t, version = v)); c2 <- try1(lake_load(t, timestamp = vs$timestamp[vs$version == v]))
    if (is_err(a) || is_err(b)) { if (!(is_err(a) && is_err(b))) msgs <- c(msgs, sprintf("v%s open/load err differ", v)); next }
    if (!identical(strip(a), strip(b))) msgs <- c(msgs, sprintf("v%s open != load", v))
    if (is_err(c2) || lake_version(c2) != v) msgs <- c(msgs, sprintf("v%s by timestamp -> %s", v, if (is_err(c2)) c2$msg else lake_version(c2)))
    if (lake_version(a) != v) msgs <- c(msgs, "version accessor")
    if (!identical(as.numeric(a$timestamp), as.numeric(vs$timestamp[vs$version == v]))) msgs <- c(msgs, sprintf("v%s snapshot ts != versions ts", v))
    ra <- try1(lake_read(a)); ca <- try1(lake_count(a)); if (!is_err(ra) && !is_err(ca) && !is.na(ca) && ca != nrow(ra)) msgs <- c(msgs, sprintf("v%s count %s != nrow %s", v, ca, nrow(ra)))
    h <- try1(lake_history(a)); if (!is_err(h) && (nrow(h) == 0 || h$version[1] != v)) msgs <- c(msgs, sprintf("v%s history head %s", v, h$version[1]))
    fa <- try1(lake_files(a)); pa <- try1(lake_partitions(a)); 
    out <- utils::capture.output(print(a)); if (!any(grepl(paste0("version ", v, "$"), out))) msgs <- c(msgs, sprintf("print version: %s", out[1]))
    if (!is_err(fa) && !any(grepl(sprintf("files: +%d ", nrow(fa)), out))) msgs <- c(msgs, sprintf("v%s print files: %s vs %d", v, grep("files", out, value = TRUE), nrow(fa)))
    if (!is_err(ca) && !is.na(ca) && !any(grepl(sprintf("records: +%s$", format(ca, big.mark = "")), gsub(",", "", out)))) msgs <- c(msgs, sprintf("v%s print records: %s vs %s", v, grep("records", out, value = TRUE), ca))
  }
  lv <- lake_version(t); if (!is_err(vs) && nrow(vs) && lv != max(vs$version)) msgs <- c(msgs, "latest != max(versions)")
  cat(sprintf("%-40s v=%s rows=%s %s\n", nm, lv, if (is_err(rd)) "ERR" else nrow(rd), if (length(msgs)) paste("\n    ", unique(msgs), collapse = "") else "ok"))
}

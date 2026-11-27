source(file.path(Sys.getenv("W"), "common.R"))
mode <- Sys.getenv("MODE")
if (mode == "opts") options(OutDec = ",", scipen = -5, digits = 3)
res <- list()
tabs <- c(list.files(FX), "MY/types", "MY/by_pl2", paste0("MY/parts/by_", c("pdec", "pts", "ptn", "pb", "ps", "pd", "pi", "pi8")))
for (nm in tabs) {
  path <- if (startsWith(nm, "MY/")) file.path(W, "t", sub("MY/", "", nm)) else file.path(FX, nm)
  t2 <- try1(lake_open(path)); if (is_err(t2)) { res[[nm]] <- t2$msg; next }
  for (fn in c("lake_files", "lake_partitions", "lake_versions", "lake_history", "lake_schema", "lake_protocol", "lake_properties", "lake_metadata", "lake_transactions", "lake_removed", "lake_domains", "lake_checkpoints", "lake_summary", "lake_read", "lake_count", "lake_log", "lake_deletion_vectors", "lake_partition_columns", "format")) {
    r <- try1(get(fn)(t2)); res[[paste(nm, fn)]] <- if (is_err(r)) r$msg else r
    if (fn %in% c("lake_files", "lake_partitions", "lake_read", "lake_history", "lake_transactions", "lake_removed")) { r <- try1(get(fn)(t2, int64 = "integer64")); res[[paste(nm, fn, "i64")]] <- if (is_err(r)) r$msg else r }
  }
  res[[paste(nm, "changes")]] <- { r <- try1(lake_changes(t2, 0)); if (is_err(r)) r$msg else r }
  res[[paste(nm, "actions")]] <- { r <- try1(lake_actions(t2, lake_version(t2))); if (is_err(r)) r$msg else r }
}
if (mode == "save") saveRDS(res, file.path(W, "base.rds")) else {
  base <- readRDS(file.path(W, "base.rds")); cat(mode, length(res), length(base), "\n")
  for (n in names(base)) if (!identical(base[[n]], res[[n]])) { cat("DIFF", n, ":", paste(utils::capture.output(print(all.equal(base[[n]], res[[n]])))[1:3], collapse = " | "), "\n") }
}

source(file.path(Sys.getenv("W"), "common.R"))
for (nm in c("table-with-dv-small", "table-with-dv-small-inline", "deletion_vectors", "zl-orders")) {
  t <- lake_open(file.path(FX, nm)); f <- lake_files(t); d <- lake_deletion_vectors(t)
  cat("==", nm, "files", nrow(f), "dvs", nrow(d), "cols:", names(d), "\n")
  sh <- function(label, e) { r <- try1(e); cat(sprintf("  %-34s %s\n", label, if (is_err(r)) paste("ERR", substr(r$msg, 1, 100)) else if (is.data.frame(r)) paste("rows", nrow(r)) else format(r))) }
  sh("files = path", lake_deletion_vectors(t, files = f$path)); sh("files = uri", lake_deletion_vectors(t, files = f$uri)); sh("files = dup", lake_deletion_vectors(t, files = c(f$path[1], f$path[1], f$uri[1])))
  sh("files = character()", lake_deletion_vectors(t, files = character())); sh("files = factor", lake_deletion_vectors(t, files = factor(f$path[1]))); sh("files = wrong", lake_deletion_vectors(t, files = "nope")); sh("files = NA", lake_deletion_vectors(t, files = NA_character_)); sh("files = 1", lake_deletion_vectors(t, files = 1))
  sh("files = basename", lake_deletion_vectors(t, files = basename(f$path[1]))); sh("files = ./path", lake_deletion_vectors(t, files = paste0("./", f$path[1]))); sh("files = uri//", lake_deletion_vectors(t, files = sub("/part", "//part", f$uri[1])))
  sh("files rev order same", identical(lake_deletion_vectors(t, files = rev(f$path)), d)); sh("rows=FALSE names", paste(names(lake_deletion_vectors(t, rows = FALSE)), collapse = ","))
  for (v in list(NA, 1, "TRUE", NULL)) sh(paste("rows =", format(v)), lake_deletion_vectors(t, rows = v))
  # card vs rows vs read
  if (nrow(d)) { cat("  cardinality == length(rows):", all(d$cardinality == lengths(d$rows)), " sorted:", all(!vapply(d$rows, is.unsorted, NA)), " class:", class(d$rows[[1]]), "\n")
    tot <- 0; for (i in seq_len(nrow(f))) tot <- tot + nrow(qio::read_parquet(f$uri[i]))
    cat("  physical rows", tot, "- deleted", sum(d$cardinality), "= read", nrow(lake_read(t)), " count", lake_count(t), " count(footers)", lake_count(t, footers = TRUE), "\n")
    # rows actually removed are at the listed positions
    for (i in seq_len(nrow(d))) { p <- qio::read_parquet(d$uri[i]); keep <- p[-(d$rows[[i]] + 1), , drop = FALSE]; got <- NULL; lake_walk(t, function(x) got[[length(got) + 1]] <<- x); 
      m <- any(vapply(got, function(g) nrow(g) == nrow(keep) && isTRUE(all.equal(g[names(keep)], keep, check.attributes = FALSE)), NA)); cat("  dv", i, "positions agree with read piece:", m, "\n") }
    print(lake_summary(t)[, c("records", "deleted_rows", "files_with_deletion_vectors")]); print(f[, grep("delet|records", names(f))][1:min(2, nrow(f)), ]) }
}

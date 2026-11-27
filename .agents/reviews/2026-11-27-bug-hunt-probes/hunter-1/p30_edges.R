source(file.path(Sys.getenv("W"), "common.R"))
tbl <- lake_open(file.path(W, "t/types"))
r <- try1(suppressWarnings(lake_read(tbl, columns = character(), filter = a > 100))); cat("columns=character() + filter: ", if (is_err(r)) r$msg else paste(dim(r), collapse = " x "), "\n")
k <- list(); suppressWarnings(lake_walk(tbl, function(p) k[[length(k) + 1]] <<- dim(p), columns = character(), filter = a > 100)); cat("walk dims:", vapply(k, paste, "", collapse = "x"), "\n")
r <- try1(suppressWarnings(lake_read(tbl, columns = character()))); cat("columns=character():", paste(dim(r), collapse = " x "), "\n")
for (n in c(100, 2000, 20000)) { v <- seq_len(n); tm <- system.time(r <- lake_read(tbl, columns = "a", filter = a %in% v))[["elapsed"]]; cat(sprintf("a %%in%% 1:%d -> %d rows, %.2fs\n", n, nrow(r), tm)) }
for (n in c(100, 2000)) { v <- as.character(seq_len(n)); tm <- system.time(r <- lake_read(tbl, columns = "a", filter = s %in% v))[["elapsed"]]; cat(sprintf("s %%in%% <%d strings> -> %d rows, %.2fs\n", n, nrow(r), tm)) }
# empty table / zero files
src <- file.path(FX, "zl-basic"); t0 <- lake_open(src); cat("zl-basic versions rows:", vapply(lake_versions(t0)$version, function(v) nrow(lake_read(lake_load(t0, version = v))), 1L), "files:", vapply(lake_versions(t0)$version, function(v) nrow(lake_files(lake_load(t0, version = v))), 1L), "\n")
for (nm in list.files(FX)) { t <- try1(lake_open(file.path(FX, nm))); if (is_err(t)) next; for (v in lake_versions(t)$version) { s <- try1(lake_load(t, version = v)); if (is_err(s) || nrow(s$files) > 0) next
  cat("zero-file snapshot:", nm, "v", v, "\n"); x <- try1(lake_read(s)); cat("   read:", if (is_err(x)) x$msg else paste(paste(dim(x), collapse = "x"), paste(names(x), collapse = ",")), "\n")
  x <- try1(lake_files(s)); cat("   files:", if (is_err(x)) x$msg else paste(dim(x), collapse = "x"), " count:", format(try1(lake_count(s))), " partitions:", paste(dim(try1(lake_partitions(s))), collapse = "x"), "\n")
  col <- lake_schema(s)$name[1]; e <- call(">", as.symbol(col), 1); x <- try1(eval(bquote(lake_read(s, filter = .(e))))); cat("   filtered read:", if (is_err(x)) x$msg else paste(dim(x), collapse = "x"), " files(filter):", { y <- try1(eval(bquote(lake_files(s, filter = .(e))))); if (is_err(y)) y$msg else nrow(y) }, "\n")
  x <- try1(eval(bquote(lake_read(s, filter = nosuchcol > 1)))); cat("   bad filter on empty:", if (is_err(x)) substr(x$msg, 1, 80) else paste("no error", paste(dim(x), collapse = "x")), "\n")
  x <- try1(lake_read(s, columns = "nosuch")); cat("   bad column on empty:", if (is_err(x)) substr(x$msg, 1, 80) else "no error", "\n")
  z <- try1(lake_read(s)); f <- try1(lake_read(t)); if (!is_err(z) && !is_err(f)) cat("   classes match full read:", identical(lapply(z, class), lapply(f[names(z)], class)), "\n")
  print(try1(lake_summary(s))); k <- 0; lake_walk(s, function(p) k <<- k + 1); cat("   walk calls:", k, "\n"); print(try1(lake_deletion_vectors(s))); break } }

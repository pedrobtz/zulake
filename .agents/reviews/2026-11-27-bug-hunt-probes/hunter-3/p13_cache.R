source("setup.R")
src <- file.path(fixture_dir(), "tables"); R <- zuhttp::zu_response
root <- tempfile("root"); dir.create(root); file.copy(file.path(src, "zl-basic"), root, recursive = TRUE)
U <- "abfss://lake@acct.dfs.core.windows.net/zl-basic"
cdir <- file.path(tempdir(), "zulake-cache")
is_data <- function(r) grepl("parquet$", r$path)
ov <- NULL
log <- new.env(); use(azure_fake(root, log, override = function(r) if (!is.null(ov)) ov(r)))
nd <- function() sum(vapply(log$requests, is_data, NA))
ref <- lake_read(lake_open(file.path(src, "zl-basic")))
t <- lake_open(U, credentials = cred)
fl <- lake_files(t); print(fl[, c("path", "size_bytes")])
datafiles <- file.path(root, "zl-basic", fl$path)
cat("== body size straddle vs log size\n")
for (d in c(-1, 0, 1)) { t <- lake_open(U, credentials = cred)
  ov <- function(r) if (is_data(r)) { b <- readBin(file.path(root, "zl-basic", basename(r$path)), "raw", 1e6); R(200L, NULL, if (d < 0) b[-length(b)] else if (d > 0) c(b, as.raw(0)) else b) }
  r <- try_(lake_read(t)); cat(" delta", d, ":", if (is.data.frame(r)) "OK" else conditionMessage(r), " cache files:", length(list.files(cdir)), " map:", length(t$downloads$files), "\n") }
ov <- NULL
cat("== half-way failure: first file ok, second 500; then retry\n")
t <- lake_open(U, credentials = cred); k <- 0; n0 <- nd()
ov <- function(r) if (is_data(r) && (k <<- k + 1) == 2) R(500L)
r <- try_(lake_read(t)); show(r); cat("  data reqs:", nd() - n0, " map:", length(t$downloads$files), " parts:", list.files(cdir, pattern = "part$"), "\n")
ov <- NULL; n0 <- nd(); r <- lake_read(t); cat("  retry same:", identical(r, ref), " data reqs:", nd() - n0, "(only the failed one)\n")
cat("== wrong size on disk (truncate / grow cached copy)\n")
hit <- unlist(t$downloads$files); print(basename(hit))
con <- file(hit[1], "ab"); writeBin(as.raw(0), con); close(con)
n0 <- nd(); r <- try_(lake_read(t)); cat("  grown by 1: same:", identical(r, ref), " data reqs:", nd() - n0, "\n")
hit <- unlist(t$downloads$files); b <- readBin(hit[1], "raw", 1e6); writeBin(b[-length(b)], hit[1])
n0 <- nd(); r <- try_(lake_read(t)); cat("  shrunk by 1: same:", identical(r, ref), " data reqs:", nd() - n0, "\n")
hit <- unlist(t$downloads$files); b <- readBin(hit[1], "raw", 1e6); b2 <- readBin(hit[2], "raw", 1e6)
cat("== same size, other content (cache poisoned on disk)\n")
writeBin(rev(b), hit[1]); n0 <- nd(); r <- try_(lake_read(t)); cat("  ", if (is.data.frame(r)) paste("read rows", nrow(r), "same:", identical(r, ref)) else paste(class(r)[1], conditionMessage(r)), " data reqs:", nd() - n0, "\n")
r <- try_(lake_read(t)); cat("   again:", if (is.data.frame(r)) "ok" else class(r)[1], "\n")
unlink(hit[1]); n0 <- nd(); r <- try_(lake_read(t)); cat("== cached copy deleted: same:", identical(r, ref), " data reqs:", nd() - n0, "\n")
cat("== cache dir removed\n"); unlink(cdir, recursive = TRUE); n0 <- nd(); r <- try_(lake_read(t)); cat("  same:", identical(r, ref), " data reqs:", nd() - n0, "\n")
cat("== cache dir is a file\n"); unlink(cdir, recursive = TRUE); writeLines("x", cdir); w <- NULL
r <- withCallingHandlers(try_(lake_read(t)), warning = function(x) { w <<- c(w, conditionMessage(x)); invokeRestart("muffleWarning") }); show(r); cat("  class:", class(r), "\n  warnings:", w, "\n"); unlink(cdir)
cat("== cache dir read-only\n"); dir.create(cdir); Sys.chmod(cdir, "0555"); w <- NULL
r <- withCallingHandlers(try_(lake_read(lake_open(U, credentials = cred))), warning = function(x) { w <<- c(w, conditionMessage(x)); invokeRestart("muffleWarning") }); show(r); cat("  class:", class(r), "\n  warnings:", w, "\n"); Sys.chmod(cdir, "0755")
cat("== map points outside cache dir (tampered / restored)\n")
t <- lake_open(U, credentials = cred); x <- lake_read(t); key <- names(t$downloads$files)[1]
other <- tempfile(fileext = ".parquet"); file.copy(t$downloads$files[[1]], other); t$downloads$files[[key]] <- other
n0 <- nd(); r <- lake_read(t); cat("  data reqs:", nd() - n0, " (1 = re-downloaded)\n")
sib <- paste0(cdir, "-evil"); dir.create(sib); o2 <- file.path(sib, "x.parquet"); file.copy(other, o2); t$downloads$files[[key]] <- o2
n0 <- nd(); r <- lake_read(t); cat("  sibling dir 'zulake-cache-evil' trusted (startsWith):", nd() - n0 == 0, "\n")
cat("== key: print one\n"); print(gsub("\x1f", " | ", names(t$downloads$files)[1], fixed = TRUE))
cat("== server replaces a data file (same name, same size) after caching -> cache; after new lake_open -> new\n")
cat("== data file deleted on server after cached\n"); file.rename(datafiles[1], paste0(datafiles[1], ".gone"))
r <- try_(lake_read(t)); cat("  cached snapshot still reads:", identical(r, ref), "\n")
r <- try_(lake_read(lake_open(U, credentials = cred))); show(r); file.rename(paste0(datafiles[1], ".gone"), datafiles[1])
cat("== walk: FUN error then next call\n")
t <- lake_open(U, credentials = cred); n0 <- nd(); k <- 0
r <- try_(lake_walk(t, function(piece, ...) { k <<- k + 1; stop("FUN failed ", k) })); show(r); cat("  class:", class(r), " FUN calls:", k, " data reqs:", nd() - n0, " parts:", length(list.files(cdir, pattern = "part$")), "\n")
n0 <- nd(); pieces <- list(); r <- try_(lake_walk(t, function(piece, ...) { pieces[[length(pieces) + 1]] <<- piece; NULL })); cat("  next walk data reqs:", nd() - n0, " rows:", sum(vapply(pieces, nrow, 1L)), " same as read:", identical(do.call(rbind, pieces)[order(do.call(rbind, pieces)$id), "id"], sort(ref$id)), "\n")
r <- try_(lake_read(t)); cat("  read after: same:", identical(r, ref), "\n")

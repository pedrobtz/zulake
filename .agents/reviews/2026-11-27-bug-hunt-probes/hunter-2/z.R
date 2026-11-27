# usage: Rscript z.R <table>[@version] ...  -- zulake's view, one block per table
.libPaths(c("/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/lib", .libPaths()))
suppressPackageStartupMessages(library(zulake))
show <- function(expr) tryCatch(expr, error = function(e) {
  cat("  ERROR <", class(e)[1], "> ", conditionMessage(e), "\n", sep = ""); NULL })
fmt <- function(x) { if (inherits(x, "POSIXct")) format(x, "%Y-%m-%dT%H:%M:%OS6", tz = "UTC") else if (is.list(x)) vapply(x, function(v) paste(format(v), collapse = " "), "") else if (is.double(x)) format(x, digits = 17) else as.character(x) }
for (arg in commandArgs(TRUE)) {
  p <- strsplit(arg, "@", fixed = TRUE)[[1]]
  v <- if (length(p) > 1) as.numeric(p[2]) else NULL
  cat("##", basename(p[1]), if (!is.null(v)) paste0("@", v), "\n")
  t <- show(lake_open(p[1], version = v))
  if (is.null(t)) next
  cat("  version:", lake_version(t), " files:", paste(sub("^.*/", "", t$files$path), collapse = " "), "\n")
  d <- show(withCallingHandlers(lake_read(t), warning = function(w) { cat("  WARN:", conditionMessage(w), "\n"); invokeRestart("muffleWarning") }))
  if (is.null(d)) next
  cat("  cols:", paste0(names(d), ":", vapply(d, function(x) class(x)[1], ""), collapse = " "), "\n")
  rows <- if (ncol(d)) do.call(paste, c(lapply(d, fmt), sep = "|")) else character()
  cat("  rows(", nrow(d), "):", paste(utils::head(sort(rows), 14), collapse = " ; "), "\n")
}

# usage: Rscript tz.R <table> <offset ms>... -- version zulake opens at BASE + offset
.libPaths(c("/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/lib", .libPaths()))
suppressPackageStartupMessages(library(zulake))
a <- commandArgs(TRUE); BASE <- 1700000000000
T <- "/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/hunt-2/t/"
cat("##", a[1], "\n")
t0 <- tryCatch(lake_open(paste0(T, a[1])), error = function(e) NULL)
if (!is.null(t0)) { v <- lake_versions(t0); cat("  versions:", paste0(v$version, "=", format((as.numeric(v$timestamp) * 1000 - BASE), digits = 15), collapse = " "), " snapshot ts:", as.numeric(t0$timestamp) * 1000 - BASE, "\n") }
for (o in as.numeric(a[-1])) {
  r <- tryCatch(lake_version(lake_open(paste0(T, a[1]), timestamp = as.POSIXct((BASE + o) / 1000, origin = "1970-01-01", tz = "UTC"))), error = function(e) paste0("ERR<", class(e)[1], "> ", substr(conditionMessage(e), 1, 150)))
  cat("  ", o, "->", r, "\n")
}

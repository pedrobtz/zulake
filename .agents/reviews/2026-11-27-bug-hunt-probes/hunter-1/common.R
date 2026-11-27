.libPaths(c("/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/lib", .libPaths()))
suppressPackageStartupMessages(library(zulake))
W <- "/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/hunt-1"
FX <- "/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/src/tests/testthat/fixtures/tables"
# copy of a table with stats removed from every add
strip_stats <- function(src, dst) {
  unlink(dst, recursive = TRUE); dir.create(dst)
  file.copy(list.files(src, full.names = TRUE, all.files = TRUE, no.. = TRUE), dst, recursive = TRUE)
  for (f in list.files(file.path(dst, "_delta_log"), pattern = "json$", full.names = TRUE)) {
    l <- readLines(f, warn = FALSE)
    l <- gsub(',"stats":"(\\\\.|[^"\\\\])*"', "", l, perl = TRUE)
    writeLines(l, f)
  }
  dst
}
try1 <- function(e) tryCatch(suppressWarnings(e), error = function(e) structure(list(msg = conditionMessage(e), cls = class(e)[1]), class = "err"))
is_err <- function(x) inherits(x, "err")
same_df <- function(a, b) {
  if (is_err(a) || is_err(b)) return(is_err(a) && is_err(b))
  rownames(a) <- NULL; rownames(b) <- NULL
  isTRUE(all.equal(a, b, tolerance = 0))
}

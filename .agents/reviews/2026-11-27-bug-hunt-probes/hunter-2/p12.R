.libPaths(c("/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/lib", .libPaths()))
suppressPackageStartupMessages(library(zulake))
T <- "/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/hunt-2/t/"
for (n in c("b_missing", "b_trunc", "b_page", "b_empty", "b_dir", "b_notparquet", "m6", "m9_dot2")) {
  cat("##", n, "\n")
  t <- lake_open(paste0(T, n))
  got <- 0; pieces <- 0
  r <- tryCatch({ lake_walk(t, function(p) { got <<- got + nrow(p); pieces <<- pieces + 1 }); "ok" }, error = function(e) paste0("ERR<", paste(class(e), collapse = ","), "> ", substr(conditionMessage(e), 1, 200)))
  cat("  walk:", r, "\n   pieces handed to FUN before:", pieces, "rows:", got, "\n")
  r <- tryCatch({ nrow(lake_read(t)) }, error = function(e) paste0("ERR<", paste(class(e), collapse = ","), "> ", substr(conditionMessage(e), 1, 200)))
  cat("  read:", r, "\n")
  r <- tryCatch({ nrow(suppressWarnings(lake_read(t, columns = "id"))) }, error = function(e) paste0("ERR<", paste(class(e), collapse = ","), "> ", substr(conditionMessage(e), 1, 200)))
  cat("  read(columns='id'):", r, "\n")
  r <- tryCatch({ lake_count(t, footers = TRUE) }, error = function(e) paste0("ERR<", paste(class(e), collapse = ","), "> ", substr(conditionMessage(e), 1, 200)))
  cat("  count(footers):", r, "\n")
}

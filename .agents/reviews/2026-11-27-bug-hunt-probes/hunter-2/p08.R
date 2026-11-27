.libPaths(c("/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/lib", .libPaths()))
suppressPackageStartupMessages(library(zulake))
T <- "/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/hunt-2/t/"
g <- function(expr) tryCatch(withCallingHandlers({ v <- expr; paste(format(v, digits = 17), collapse = ",") }, warning = function(w) { cat("     [warn]", conditionMessage(w), "\n"); invokeRestart("muffleWarning") }), error = function(e) paste0("ERR<", sub("zulake_error_", "", class(e)[1]), "> ", conditionMessage(e)))
for (n in sort(list.files(T, pattern = "^n_"))) {
  cat("##", n, "\n")
  t <- tryCatch(lake_open(paste0(T, n)), error = function(e) { cat("  open: ERR<", class(e)[1], ">", conditionMessage(e), "\n"); NULL })
  if (is.null(t)) next
  cat("  count:", g(lake_count(t)), " footers:", g(lake_count(t, footers = TRUE)), " nrow(read):", g(nrow(lake_read(t))), "\n")
  cat("  files size:", g(lake_files(t)$size), " mtime:", g(as.numeric(lake_files(t)$modification_time)), " numrec:", g(lake_files(t)$num_records), " dc:", g(lake_files(t)$data_change), "\n")
  if (grepl("txn", n)) cat("  txn:", g(lake_transactions(t)$version), "| lu:", g(as.numeric(lake_transactions(t)$last_updated)), "\n")
}

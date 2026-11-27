source("setup.R")
src <- file.path(fixture_dir(), "tables")
options(zulake.azure_client = NULL, zulake.azure_endpoint = "http://127.0.0.1:18731/acct")
ctl <- function(port, what) rawToChar(zuhttp::zu_resp_raw(zuhttp::zu_get(sprintf("http://127.0.0.1:%d/%s", port, what))))
ctl(18731, "__mode?m=")
U <- function(t) paste0("abfss://lake@acct.dfs.core.windows.net/", t)
tabs <- c("zl-basic", "zl-checkpoint", "zl-partitioned", "zl-orders", "simple_table", "zl-file-times")
want <- lapply(tabs, function(n) { t <- lake_open(file.path(src, n)); list(v = lake_version(t), files = lake_files(t)$path, read = lake_read(t)) })
# parent opens every table: the pool now holds a live keep-alive connection
snaps <- lapply(tabs, function(n) lake_open(U(n), credentials = cred))
print(zuhttp::zu_pool_stats(zulake:::azure_env$client))
bad <- 0; errs <- character()
for (round in 1:15) {
  res <- parallel::mclapply(seq_along(tabs), function(i) {
    out <- tryCatch({ t <- lake_load(snaps[[i]]); list(v = lake_version(t), files = lake_files(t)$path, read = lake_read(t)) }, error = function(e) e)
    out
  }, mc.cores = length(tabs), mc.preschedule = FALSE)
  for (i in seq_along(tabs)) {
    r <- res[[i]]
    if (inherits(r, "condition") || inherits(r, "try-error")) { bad <- bad + 1; errs <- c(errs, paste(tabs[i], class(r)[1], substr(conditionMessage(r), 1, 150))) }
    else if (!identical(r, want[[i]])) { bad <- bad + 1; errs <- c(errs, paste(tabs[i], "WRONG RESULT: v", r$v, "want", want[[i]]$v, " rows", nrow(r$read), "want", nrow(want[[i]]$read))) }
  }
}
cat("children bad results:", bad, "of", 15 * length(tabs), "\n"); print(table(errs))
# parent after the forks
r <- try_(lapply(seq_along(tabs), function(i) identical(lake_read(lake_load(snaps[[i]])), want[[i]]$read))); cat("parent after forks:"); print(unlist(r))
cat("parent cache untouched by children: map sizes", vapply(snaps, function(s) length(s$downloads$files), 1L), "\n")

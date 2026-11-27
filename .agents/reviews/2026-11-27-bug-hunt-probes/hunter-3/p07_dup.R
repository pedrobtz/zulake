source("setup.R")
root <- file.path(fixture_dir(), "tables"); R <- zuhttp::zu_response
D <- "Thu, 26 Nov 2026 16:04:00 GMT"
mk <- function(tbl, fs) R(200L, body = charToRaw(paste0("<EnumerationResults><Blobs>", paste(sprintf("<Blob><Name>%s/_delta_log/%s</Name><Properties><Last-Modified>%s</Last-Modified><Content-Length>%s</Content-Length></Properties></Blob>", tbl, fs, D, file.size(file.path(root, tbl, "_delta_log", fs))), collapse = ""), "</Blobs><NextMarker /></EnumerationResults>")))
for (tbl in c("zl-basic", "zl-checkpoint")) {
  files <- list.files(file.path(root, tbl, "_delta_log"))
  for (i in seq_along(files)) {
    log <- new.env()
    use(azure_fake(root, log, override = function(r) if (identical(r$query$comp, "list")) mk(tbl, c(files, files[i]))))
    e <- tryCatch(withCallingHandlers(lake_open(paste0("abfss://lake@acct.dfs.core.windows.net/", tbl), credentials = cred),
       error = function(e) if (!inherits(e, "zulake_error")) tb <<- sys.calls()), error = function(e) e)
    if (inherits(e, "zulake_table")) {
      ref <- lake_open(fixture_table(tbl))
      cat(tbl, "dup", files[i], ": opened v", lake_version(e), " read same:", identical(lake_read(e), lake_read(ref)), " log rows:", nrow(lake_log(e)), "vs", nrow(lake_log(ref)), " history same:", identical(lake_history(e)$version, lake_history(ref)$version), "\n")
    } else { cat(tbl, "dup", files[i], ": <", class(e)[1], ">", conditionMessage(e), "\n"); if (!inherits(e, "zulake_error")) print(tail(lapply(tb, function(x) deparse(x)[1]), 8)) }
  }
}
cat("---- detail: dup of commit 2 in zl-basic\n")
tbl <- "zl-basic"; files <- list.files(file.path(root, tbl, "_delta_log"))
use(azure_fake(root, new.env(), override = function(r) if (identical(r$query$comp, "list")) mk(tbl, c(files, files[3]))))
e <- lake_open("abfss://lake@acct.dfs.core.windows.net/zl-basic", credentials = cred)
print(lake_history(e)[, 1:3]); print(lake_log(e)[, 1:3]); print(lake_versions(e))
print(try_(lake_changes(e, 1, 3))[, 1:4])

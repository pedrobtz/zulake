source("setup.R")
root <- file.path(fixture_dir(), "tables")
R <- zuhttp::zu_response
U <- "abfss://lake@acct.dfs.core.windows.net/zl-checkpoint"
local_ref <- lake_read(lake_open(fixture_table("zl-checkpoint")))
cat("== page sizes\n")
for (ps in c(1, 2, 3, 5, 1000)) {
  log <- new.env(); use(azure_fake(root, log, page_size = ps))
  t <- lake_open(U, credentials = cred)
  lists <- Filter(function(r) identical(r$query$comp, "list"), log$requests)
  cat("page", ps, "requests", length(log$requests), "lists", length(lists), "markers", paste(vapply(lists, function(r) r$query$marker %||% "-", ""), collapse = ","), "same:", identical(lake_read(t), local_ref), " v", lake_version(t), "\n")
}
D <- "Thu, 26 Nov 2026 16:04:00 GMT"
files <- list.files(file.path(root, "zl-checkpoint/_delta_log"))
blob <- function(f, len = file.size(file.path(root, "zl-checkpoint/_delta_log", f))) sprintf("<Blob><Name>zl-checkpoint/_delta_log/%s</Name><Properties><Last-Modified>%s</Last-Modified><Content-Length>%s</Content-Length></Properties></Blob>", f, D, format(len, scientific = FALSE))
doc <- function(fs, marker = NULL, lens = NULL) R(200L, body = charToRaw(paste0("<EnumerationResults><Blobs>", paste(if (is.null(lens)) vapply(fs, blob, "") else mapply(blob, fs, lens), collapse = ""), "</Blobs>", if (is.null(marker)) "<NextMarker />" else paste0("<NextMarker>", marker, "</NextMarker>"), "</EnumerationResults>")))
run <- function(label, pages, expr = quote(lake_open(U, credentials = cred))) {
  log <- new.env(); k <- 0
  use(azure_fake(root, log, max_requests = 60L, override = function(r) if (identical(r$query$comp, "list")) { k <<- k + 1; p <- pages(k, r); p }))
  e <- try_(eval(expr)); cat("==", label, ": requests", length(log$requests), " list calls", k, "\n"); 
  if (inherits(e, "zulake_table")) cat("  opened version", lake_version(e), "files", nrow(lake_files(e)), " read same:", identical(try_(lake_read(e)), local_ref), "\n") else show(e)
  lists <- Filter(function(r) identical(r$query$comp, "list"), log$requests)
  cat("  markers sent:", paste(vapply(lists, function(r) encodeString(r$query$marker %||% "-"), ""), collapse = " | "), "\n")
  invisible(e)
}
print(files)
h <- files[1:3]; rest <- files[-(1:3)]
run("500 on page 2", function(k, r) if (k == 1) doc(h, "m1") else R(500L))
run("ContainerNotFound on page 2", function(k, r) if (k == 1) doc(h, "m1") else R(404L, c(`x-ms-error-code` = "ContainerNotFound")))
run("ContainerNotFound p2, is_table", function(k, r) if (k == 1) doc(h, "m1") else R(404L, c(`x-ms-error-code` = "ContainerNotFound")), quote(lake_is_table(U, credentials = cred)))
run("marker A,B,A", function(k, r) doc(h, c("A", "B", "A")[min(k, 3)]))
run("marker same", function(k, r) doc(h, "A"))
run("empty page with marker then rest", function(k, r) if (k == 1) doc(character(), "m1") else if (k == 2) doc(h, "m2") else doc(rest))
run("marker special chars", function(k, r) if (k == 1) doc(h, "2!76!a+b/c=&amp;d %41 é==") else doc(rest))
run("duplicate blob across pages", function(k, r) if (k == 1) doc(files, "m1") else doc(files[1:2]))
run("duplicate blob in a page", function(k, r) doc(c(files, files[length(files)])))
run("page 2 has names sorting before page 1 (unordered)", function(k, r) if (k == 1) doc(rest, "m1") else doc(h))
run("only first page (server drops marker): partial log", function(k, r) doc(h))
run("listing sizes all 0", function(k, r) doc(files, lens = rep(0, length(files))))
run("listing sizes all huge", function(k, r) doc(files, lens = rep(2^40, length(files))))
run("whitespace marker", function(k, r) if (k == 1) doc(h, " ") else doc(rest))
run("100 pages of 1 distinct marker", function(k, r) if (k <= length(files) - 1) doc(files[k], paste0("m", k)) else doc(files[k]))

source("setup.R")
options(zulake.azure_client = NULL, zulake.azure_endpoint = "http://127.0.0.1:18731/acct")
U <- "abfss://lake@acct.dfs.core.windows.net/zl-basic"
ctl <- function(port, what) rawToChar(zuhttp::zu_resp_raw(zuhttp::zu_get(sprintf("http://127.0.0.1:%d/%s", port, what))))
mode <- function(m) { ctl(18731, paste0("__mode?m=", m)); ctl(18732, paste0("__mode?m=", m)) }
logs <- function() c(jsonlite::fromJSON(ctl(18731, "__log"), simplifyVector = FALSE), jsonlite::fromJSON(ctl(18732, "__log"), simplifyVector = FALSE))
run <- function(m, expr = quote(lake_read(lake_open(U, credentials = cred)))) {
  mode(m); w <- list()
  e <- withCallingHandlers(try_(eval(expr)), warning = function(x) { w[[length(w) + 1]] <<- x; invokeRestart("muffleWarning") })
  L <- logs()
  cat("== mode", m, ": requests", length(L), "\n"); show(e)
  if (inherits(e, "condition")) { f <- unclass(e); f$message <- NULL; cat("   fields:", paste(names(f), vapply(f, function(v) paste(format(v), collapse = ","), ""), sep = "=", collapse = "; "), "\n") }
  cat("   token leak in cond:", has_token(e), " warnings:", length(w), "\n")
  print(table(vapply(L, function(r) paste("port", r$port, "auth", !is.null(r$headers$authorization), "ua", r$headers$`user-agent`), "")))
  invisible(e)
}
base <- run("")
print(base)
run("redirect_list")
run("redirect_data")
run("redirect_data_localhost")
run("503_once")
run("drop_once")
e <- run("drop_data"); print(class(e)); 
run("short_list")
r <- run("short_commit"); 
r <- run("short_commit_nolen"); if (is.data.frame(r)) { cat("identical to base:", identical(r, base), "\n"); print(r) }
r <- run("short_commit_chunked"); if (is.data.frame(r)) { cat("identical to base:", identical(r, base), "\n"); print(r) }
run("short_data")
run("gzip_commit")
# connection refused
options(zulake.azure_endpoint = "http://127.0.0.1:18739/acct")
e <- try_(lake_open(U, credentials = cred)); show(e); cat("leak:", has_token(e), "\n"); str(unclass(e))

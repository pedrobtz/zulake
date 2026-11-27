source("setup.R")
root <- file.path(fixture_dir(), "tables")
U <- "abfss://lake@acct.dfs.core.windows.net/zl-basic"
cat("== calling handler sees zu_error? (native, refused / dropped)\n")
options(zulake.azure_client = NULL, zulake.azure_endpoint = "http://127.0.0.1:18739/acct")
seen <- list()
r <- try_(withCallingHandlers(lake_open(U, credentials = cred), condition = function(e) seen[[length(seen) + 1]] <<- e))
for (s in seen) cat("  handler saw:", class(s)[1], " token:", has_token(s), " fields:", names(unclass(s)), "\n")
ctl <- function(port, what) rawToChar(zuhttp::zu_resp_raw(zuhttp::zu_get(sprintf("http://127.0.0.1:%d/%s", port, what))))
options(zulake.azure_endpoint = "http://127.0.0.1:18731/acct")
for (m in c("drop_data", "short_data", "short_list")) { ctl(18731, paste0("__mode?m=", m)); seen <- list()
  r <- try_(withCallingHandlers(lake_read(lake_open(U, credentials = cred)), condition = function(e) seen[[length(seen) + 1]] <<- e))
  for (s in seen) { cat(" ", m, "handler saw:", class(s)[1:2], " token:", has_token(s), " fields:", names(unclass(s)), "\n"); if (has_token(s)) cat("     at:", token_path(s, "SECRETto"), "\n") } }
ctl(18731, "__mode?m=")

cat("== time limit / interrupt inside the transport\n")
cdir <- file.path(tempdir(), "zulake-cache")
slow <- FALSE; act <- NULL
log <- new.env(); use(azure_fake(root, log, override = function(r) { if (!is.null(act) && grepl("parquet$", r$path)) act(); NULL }))
t <- lake_open(U, credentials = cred)
act <- function() { setTimeLimit(elapsed = 0.05, transient = TRUE); Sys.sleep(1) }
r <- try_(lake_read(t)); setTimeLimit(); show(r); cat("  class:", class(r), " leak:", has_token(r), " cache dir:", list.files(cdir), "\n")
act <- function() tools::pskill(Sys.getpid(), tools::SIGINT)
r <- tryCatch({ lake_read(t); Sys.sleep(0.5); "no interrupt" }, interrupt = function(i) i, error = function(e) e); cat("  interrupt result:", class(r)[1], " cache dir:", list.files(cdir), "\n")
act <- NULL
r <- try_(lake_read(t)); cat("  next read ok:", is.data.frame(r) && nrow(r) == 3, " cache dir:", length(list.files(cdir)), "\n")

cat("== time limit inside credentials()\n")
k <- 0
cr <- function() { k <<- k + 1; if (k == 1) { setTimeLimit(elapsed = 0.05, transient = TRUE); Sys.sleep(1) }; TOKEN }
r <- try_(lake_open(U, credentials = cr)); setTimeLimit(); show(r); cat("  class:", class(r), "\n")
r <- try_(lake_open(U, credentials = cr)); cat("  second open:", class(r)[1], "\n")
cat("== credentials() signalling a warning / a message / a non-error condition / returning invisible / erroring with classed cond\n")
r <- withCallingHandlers(try_(lake_open(U, credentials = function() { warning("warn ", "w"); TOKEN })), warning = function(w) { cat("  warning passed:", conditionMessage(w), "\n"); invokeRestart("muffleWarning") }); cat("  ", class(r)[1], "\n")
r <- try_(lake_open(U, credentials = function() stop(structure(class = c("my_auth_error", "error", "condition"), list(message = "my classed", call = NULL, secret = TOKEN))))); show(r); cat("  classes:", class(r), " fields:", names(unclass(r)), " leak:", has_token(r), "\n")
r <- try_(lake_open(U, credentials = function() rlang::abort("rlang abort", class = "x"))); show(r)
r <- tryCatch(lake_open(U, credentials = function() signalCondition(structure(class = c("interrupt", "condition"), list()))), interrupt = function(i) "interrupt propagated", error = function(e) e); print(class(r)[1])
cat("== credentials with args / primitive / closure env captured?\n")
r <- try_(lake_open(U, credentials = function(x) TOKEN)); cat("  function(x):", class(r)[1], "\n")
r <- try_(lake_open(U, credentials = function(...) TOKEN)); cat("  function(...):", class(r)[1], "\n")
r <- try_(lake_open(U, credentials = "token")); show(r)
r <- try_(lake_open(U, credentials = TOKEN)); show(r); cat("  leak when token passed as string:", has_token(r), "\n")
r <- try_(lake_open(fixture_table("zl-basic"), credentials = cr)); cat("  local with credentials:", class(r)[1], "\n")

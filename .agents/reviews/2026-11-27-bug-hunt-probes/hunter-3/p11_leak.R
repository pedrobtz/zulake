source("setup.R")
options(zulake.azure_client = NULL, zulake.azure_endpoint = "http://127.0.0.1:18731/acct")
U <- "abfss://lake@acct.dfs.core.windows.net/zl-basic"
ctl <- function(port, what) rawToChar(zuhttp::zu_resp_raw(zuhttp::zu_get(sprintf("http://127.0.0.1:%d/%s", port, what))))
ctl(18731, "__mode?m=")
t <- lake_open(U, credentials = cred); x <- lake_read(t)
cat("native client holds token:", has_token(zulake:::azure_env$client), "\n")
cat("azure_env:", ls(zulake:::azure_env), " holds token:", has_token(as.list(zulake:::azure_env)), "\n")
cat("zuhttp default client:", has_token(zuhttp::zu_default_client()), "\n")
cat("options:", has_token(options()), "\n")
cat("snapshot:", has_token(t), " storage closures env:", has_token(as.list(environment(t$storage$get))), "\n")
cat("zulake namespace (non-registry) :", any(vapply(setdiff(ls(asNamespace("zulake"), all.names = TRUE), "credential_env"), function(n) { v <- get(n, asNamespace("zulake")); if (is.environment(v) && !identical(v, zulake:::credential_env)) has_token(as.list(v)) else FALSE }, NA)), "\n")
cat("registry holds token (expected TRUE):", has_token(as.list(zulake:::credential_env)), "\n")
# traceback / sys.calls at the error, native transport failure
check_calls <- function(expr) {
  calls <- NULL; cond <- NULL
  tryCatch(withCallingHandlers(expr, error = function(e) { calls <<- sys.calls(); frames <- sys.frames(); cond <<- e }), error = function(e) NULL)
  txt <- unlist(lapply(calls, function(cl) paste(deparse(cl), collapse = " ")))
  cat("  cond:", class(cond)[1], conditionMessage(cond), "\n  token in deparsed calls:", any(grepl("SECRETto", txt, fixed = TRUE)), " in cond:", has_token(cond), "\n")
}
cat("== drop_data\n"); ctl(18731, "__mode?m=drop_data"); check_calls(lake_read(lake_open(U, credentials = cred)))
cat("== refused\n"); options(zulake.azure_endpoint = "http://127.0.0.1:18739/acct"); check_calls(lake_open(U, credentials = cred))
cat("== timeout via setTimeLimit inside request (interrupt)\n")
options(zulake.azure_endpoint = "http://127.0.0.1:18731/acct"); ctl(18731, "__mode?m=")
t <- lake_open(U, credentials = cred)
tbk <- try_({ setTimeLimit(elapsed = 0.001, transient = TRUE); lake_read(lake_load(t)) }); setTimeLimit(); show(tbk); cat("  leak:", has_token(tbk), "\n")
r <- try_(lake_read(t)); cat("after time limit, read ok:", identical(r, x), "\n")
r <- try_(lake_load(t)); cat("after time limit, load ok:", class(r)[1], "\n")
cat("== warnings on normal path\n"); w <- NULL
withCallingHandlers(lake_read(lake_open(U, credentials = cred)), warning = function(x) w <<- c(w, conditionMessage(x)), message = function(m) w <<- c(w, conditionMessage(m))); print(w)
cat("== verbose/trace options\n")
out <- capture.output(type = "message", o2 <- capture.output({ op <- options(zuhttp.verbose = TRUE, verbose = TRUE); try(lake_open(U, credentials = cred)); options(op) }))
cat("token in verbose output:", any(grepl("SECRETto", c(out, o2))), length(out), length(o2), "\n")

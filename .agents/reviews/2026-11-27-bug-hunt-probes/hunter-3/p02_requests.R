source("setup.R")
root <- file.path(fixture_dir(), "tables")
sig <- function(log) vapply(log$requests, function(r) paste(r$method, r$url, r$headers$authorization, r$headers$range %||% ""), "")
cat("== three forms, same requests\n")
res <- list(); sigs <- list()
for (u in c("abfss://lake@acct.dfs.core.windows.net/zl-partitioned", "https://acct.dfs.core.windows.net/lake/zl-partitioned",
            "https://acct.blob.core.windows.net/lake/zl-partitioned", "HTTPS://ACCT.BLOB.CORE.WINDOWS.NET/lake/zl-partitioned/",
            "https://acct.blob.core.windows.net/lake/zl%2Dpartitioned", "https://acct.blob.core.windows.net/lake/%7Al-partitioned")) {
  log <- new.env(); use(azure_fake(root, log))
  t <- lake_open(u, credentials = cred); res[[u]] <- lake_read(t); sigs[[u]] <- sig(log)
  cat(u, length(log$requests), "requests; all auth:", all(vapply(log$requests, function(r) identical(r$headers$authorization, paste("Bearer", TOKEN)), NA)),
      "hosts:", unique(vapply(log$requests, function(r) r$host, "")), "\n")
}
cat("identical results:", all(vapply(res, identical, NA, res[[1]])), " identical requests:", all(vapply(sigs, identical, NA, sigs[[1]])), "\n")
print(table(sub("\\?.*", "", sub(" Bearer.*", "", sigs[[1]]))))
print(unique(names(log$requests[[1]]$headers))); print(log$requests[[1]]$url)

cat("== 401 then accepted\n")
n <- 0; log <- new.env()
use(azure_fake(root, log, auth = function(h) if (!identical(h, "Bearer tok-2")) 401L))
t <- lake_open("abfss://lake@acct.dfs.core.windows.net/zl-basic", credentials = function() { n <<- n + 1; paste0("tok-", n) })
cat("cred calls", n, "requests", length(log$requests), "\n"); print(vapply(log$requests, function(r) r$headers$authorization, ""))
x <- lake_read(t); cat("cred calls after read", n, "requests", length(log$requests), "\n")

cat("== always 401\n")
n <- 0; log <- new.env(); use(azure_fake(root, log, auth = function(h) 401L))
e <- try_(lake_open("abfss://lake@acct.dfs.core.windows.net/zl-basic", credentials = function() { n <<- n + 1; TOKEN })); show(e)
cat("cred calls", n, "requests", length(log$requests), "token in cond:", has_token(e), "\n"); str(unclass(e)[-1])

cat("== credentials failing then succeeding\n")
n <- 0; log <- new.env(); use(azure_fake(root, log))
cr <- function() { n <<- n + 1; if (n == 1) stop("boom ", TOKEN) else TOKEN }
e <- try_(lake_open("abfss://lake@acct.dfs.core.windows.net/zl-basic", credentials = cr)); show(e); cat("requests", length(log$requests), "\n")
t <- lake_open("abfss://lake@acct.dfs.core.windows.net/zl-basic", credentials = cr); cat("second open ok; n =", n, "\n")
cat("registry size:", length(ls(zulake:::credential_env)), "\n"); gc(); cat("after gc:", length(ls(zulake:::credential_env)), "\n")

cat("== credentials failing on refresh (401), then next call\n")
n <- 0; phase <- "ok"; log <- new.env()
use(azure_fake(root, log, auth = function(h) if (phase == "expired") 401L))
cr <- function() { n <<- n + 1; if (phase == "expired") stop("cannot refresh") else TOKEN }
t <- lake_open("abfss://lake@acct.dfs.core.windows.net/zl-basic", credentials = cr)
phase <- "expired"; e <- try_(lake_read(t)); show(e)
phase <- "ok"; r <- try_(lake_read(t)); cat("after recovery rows:", if (is.data.frame(r)) nrow(r) else conditionMessage(r), " n=", n, "\n")

cat("== token shapes\n")
for (tok in list("Bearer abc", "bearer   abc", "BEARER abc", "Bearer", "Bearer ", "Bearer Bearer abc", "a b", "abc\n", "abc\r\nX-Evil: 1", "\tabc", "abc d", "abc d", "café", NA_character_, c("a","b"), 1, NULL, "", structure("abc", class = "foo"), "Bearer\tabc")) {
  log <- new.env(); use(azure_fake(root, log))
  e <- try_(lake_open("abfss://lake@acct.dfs.core.windows.net/zl-basic", credentials = function() tok))
  cat(deparse(tok), "->", if (inherits(e, "condition")) paste(class(e)[1], conditionMessage(e)) else paste("sent:", encodeString(unique(vapply(log$requests, function(r) r$headers$authorization %||% "<none>", "")), quote = '"')), "\n")
}

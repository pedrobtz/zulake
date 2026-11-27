source("setup.R")
root <- file.path(fixture_dir(), "tables"); R <- zuhttp::zu_response
U <- "abfss://lake@acct.dfs.core.windows.net/zl-basic"
ref <- lake_read(lake_open(fixture_table("zl-basic")))
for (v in 0:4) for (drop in 1:2) {
  f <- file.path(root, "zl-basic/_delta_log", sprintf("%020d.json", v)); lines <- readLines(f)
  if (drop >= length(lines)) next
  body <- charToRaw(paste0(paste(head(lines, -drop), collapse = "\n"), "\n"))
  use(azure_fake(root, new.env(), override = function(r) if (grepl(basename(f), r$path, fixed = TRUE)) R(200L, c(`Last-Modified` = "Thu, 26 Nov 2026 16:04:00 GMT"), body)))
  r <- try_({ t <- lake_open(U, credentials = cred); lake_read(t) })
  cat("commit", v, "body cut by", drop, "line(s) (", length(body), "of", file.size(f), "bytes; listing said", file.size(f), "):",
      if (is.data.frame(r)) paste("read OK, rows", nrow(r), "(true:", nrow(ref), ") identical:", identical(r, ref)) else paste(class(r)[1], substr(conditionMessage(r), 1, 80)), "\n")
}

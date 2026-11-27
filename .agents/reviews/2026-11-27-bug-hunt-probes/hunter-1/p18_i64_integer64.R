source(file.path(Sys.getenv("W"), "common.R")); source(file.path(W, "lits.R")); suppressPackageStartupMessages(library(bit64))
tbl <- lake_open(file.path(W, "t/types")); ns <- lake_open(file.path(W, "t/types_nostats"))
full <- suppressWarnings(lake_read(tbl, columns = c("i64", "a"), int64 = "integer64"))
lits <- c(lits, list(i64a = as.integer64("9007199254740993"), i64b = as.integer64("-9007199254740993"), i64na = NA_integer64_, i64v = as.integer64(c("1", "9223372036854775807"))))
bad <- 0
for (ln in names(lits)) for (e in c(mk_exprs("i64", lits[[ln]]), list(quote(is.na(i64)), quote(!is.na(i64))))) {
  if (length(lits[[ln]]) > 1 && !grepl("%in%", deparse(e)[1])) next
  a <- try1(eval(bquote(lake_read(tbl, columns = c("i64", "a"), int64 = "integer64", filter = .(e)))))
  b <- try1(eval(bquote(lake_read(ns, columns = c("i64", "a"), int64 = "integer64", filter = .(e)))))
  r <- try1({ x <- eval(e, full, globalenv()); full[x %in% TRUE, , drop = FALSE] })
  lab <- sprintf("%-40s [%s]", paste(deparse(e, width.cutoff = 200), collapse = "")[1], ln)
  if (!same_df(a, b)) { bad <- bad + 1; if (bad < 12) cat("PRUNE-DIFF", lab, if (is_err(a)) a$msg else paste(a$a, collapse = ","), "|", if (is_err(b)) b$msg else paste(b$a, collapse = ","), "\n") }
  else if (!is_err(a) && !is_err(r) && !setequal(a$a, r$a)) cat("REF-DIFF  ", lab, paste(a$a, collapse = ","), "|", paste(r$a, collapse = ","), "\n")
}
cat("prune diffs", bad, "\n")

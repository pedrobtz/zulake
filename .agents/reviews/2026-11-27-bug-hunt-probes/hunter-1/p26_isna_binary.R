source(file.path(Sys.getenv("W"), "common.R"))
t <- lake_open(file.path(FX, "zl-types"))
for (e in alist(is.na(b), !(!is.na(b)), is.na(b) == TRUE, is.na(b) & TRUE, xor(is.na(b), FALSE), is.na(b) | FALSE, !is.na(b), is.na(b) == FALSE, is.na(b) != TRUE, is.na(b) == is.na(s), is.na(s) == TRUE, b %in% NA, s %in% NA)) {
  a <- try1(eval(bquote(suppressWarnings(lake_read(t, columns = "i8", filter = .(e))))))
  cat(sprintf("%-26s -> i8: %s\n", deparse(e), if (is_err(a)) paste("ERR", substr(a$msg, 1, 80)) else paste(a$i8, collapse = ",")))
}

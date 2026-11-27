source(file.path(Sys.getenv("W"), "common.R"))
tbl <- lake_open(file.path(W, "t/types")); pd <- lake_open(file.path(W, "t/parts/by_pdec"))
run <- function() for (e in alist(dec == 12.3, dec > 0, dec %in% c(0.1, 1), a == 100, a > 50.5, dec15 == 0.00001, i16 == 32767, f64 == 0.1, pdec == 12.3, pdec > 0.05)) {
  on_pd <- "pdec" %in% all.vars(e)
  r <- try1(suppressMessages(suppressWarnings(eval(bquote(lake_read(.(if (on_pd) pd else tbl), columns = .(if (on_pd) "id" else "a"), filter = .(e)))))))
  cat(sprintf("  %-22s %s\n", deparse(e), if (is_err(r)) paste("ERR", substr(r$msg, 1, 110)) else paste(r[[1]], collapse = ",")))
}
cat("LC_NUMERIC = C\n"); run()
cat("set:", suppressWarnings(Sys.setlocale("LC_NUMERIC", "de_DE.UTF-8")), " sprintf:", sprintf("%.2f", 1.5), "\n"); run()

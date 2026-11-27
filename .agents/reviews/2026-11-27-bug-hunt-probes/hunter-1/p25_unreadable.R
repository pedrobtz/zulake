source(file.path(Sys.getenv("W"), "common.R"))
t <- lake_open(file.path(FX, "zl-types")); full <- suppressWarnings(lake_read(t)); cat(names(full), "\n"); str(full$b); print(full[, c("i8", "s", "dec")])
ns <- lake_open(strip_stats(file.path(FX, "zl-types"), file.path(W, "t/fx_nostats")))
sh <- function(e) { a <- try1(eval(bquote(lake_read(t, columns = "i8", filter = .(e))))); b <- try1(eval(bquote(lake_read(ns, columns = "i8", filter = .(e))))); f <- try1(eval(bquote(lake_files(t, filter = .(e)))))
  cat(sprintf("%-34s pruned: %-40s nostats: %-22s files: %s\n", deparse(e), if (is_err(a)) paste("ERR", substr(a$msg, 1, 34)) else paste(a$i8, collapse = ","), if (is_err(b)) "ERR" else paste(b$i8, collapse = ","), if (is_err(f)) paste("ERR", substr(f$msg, 20, 60)) else nrow(f))) }
for (e in alist(is.na(b), !is.na(b), b == 1, is.na(b) | i8 > 0, is.na(dec38), !is.na(dec38), dec38 > 1, dec38 == "1.5", is.na(st), !is.na(st), is.na(li), is.na(mp), st == 1, is.na(st) | TRUE, i8 > 0 | is.na(st), i8 > 1000 & is.na(st), i8 > 1000 & dec38 > 1, FALSE & is.na(st),
  lengths(b) > 1, nchar(b) > 1, is.na(b) == is.na(s), !(b %in% 1), b %in% NA, b %in% list(NULL), is.na(flag), flag, !flag, flag == TRUE & !is.na(b))) sh(e)

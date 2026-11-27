source(file.path(Sys.getenv("W"), "common.R")); source(file.path(W, "lits.R"))
suppressPackageStartupMessages(library(bit64))
tbl <- lake_open(file.path(W, "t/by_pl2"))
full <- lake_read(tbl, int64 = "integer64"); print(full[, c("id", "pl")])
truth <- c(`1` = "1", `2` = "9007199254740991", `3` = "9007199254740993", `4` = "9223372036854775807", `5` = "-9223372036854775808", `6` = NA, `7` = "0", `8` = "-5")
cat("lake_files partitions:\n"); print(lake_partitions(tbl, int64 = "integer64")); print(try1(lake_partitions(tbl)))
# exact reference using Rmpfr-free approach: compare via zulake's own text? use gmp if present
have_gmp <- requireNamespace("gmp", quietly = TRUE); cat("gmp:", have_gmp, "\n")
es <- alist(pl == "9007199254740993", pl == 9007199254740993, pl > 2^53, pl >= "9007199254740992", pl < "-9223372036854775807", pl == "-9223372036854775808", pl <= -2^63, pl < -2^63, pl >= 2^63, pl > "9223372036854775806",
  pl == as.integer64("9223372036854775807"), pl %in% as.integer64(c("9007199254740993", "1")), pl %in% c("9007199254740993", NA), is.na(pl), !is.na(pl), pl != 0, pl > 0.5, pl < 0.5, pl == 1e19, pl < 1e19, pl == "1e0", pl == "+1", pl == "01", pl == " 1", pl == "1.0", pl == "0x1",
  pl == as.integer64(NA), pl %in% as.integer64(NA), pl > as.integer64(0), pl == Inf, pl < Inf, pl > -Inf, pl == 9007199254740992, pl > 9007199254740992, pl + 0 == 1, pl == TRUE, pl == 1L)
for (e in es) for (m in c("integer64", "double")) {
  a <- try1(eval(bquote(lake_read(tbl, filter = .(e), int64 = "integer64"))))
  f <- try1(eval(bquote(lake_files(tbl, filter = .(e), int64 = .(m)))))
  cat(sprintf("%-50s %-9s read: %-22s files: %s\n", deparse(e), m, if (is_err(a)) paste("ERR", substr(a$msg, 30, 80)) else paste(a$id, collapse = ","), if (is_err(f)) paste("ERR", substr(f$msg, 1, 90)) else nrow(f)))
}

source(file.path(Sys.getenv("W"), "common.R"))
tbl <- lake_open(file.path(W, "t/types"))
full <- suppressWarnings(lake_read(tbl, columns = c("i64", "a")))
print(full, digits = 17)
cat("subset is.na:\n"); print(subset(full, is.na(i64))$a)
cat("filter is.na:\n"); print(suppressWarnings(lake_read(tbl, columns = c("i64", "a"), filter = is.na(i64)))$a)
cat("files is.na:", nrow(lake_files(tbl, filter = is.na(i64))), "of", nrow(lake_files(tbl)), "\n")
cat("filter !is.na:\n"); print(suppressWarnings(lake_read(tbl, columns = c("i64", "a"), filter = !is.na(i64)))$a)
cat("subset !is.na:\n"); print(subset(full, !is.na(i64))$a)
cat("filter !(i64 %in% 0):\n"); print(suppressWarnings(lake_read(tbl, columns = c("i64", "a"), filter = !(i64 %in% 0)))$a)
cat("subset:\n"); print(subset(full, !(i64 %in% 0))$a)
cat("filter i64 %in% NA:\n"); print(suppressWarnings(lake_read(tbl, columns = c("i64", "a"), filter = i64 %in% NA))$a)
cat("subset:\n"); print(subset(full, i64 %in% NA)$a)
# integer64
f2 <- lake_read(tbl, columns = c("i64", "a"), int64 = "integer64")
print(f2)
for (e in list(quote(i64 > 2^53), quote(i64 == "9007199254740993"), quote(i64 == bit64::as.integer64("9223372036854775807")),
               quote(i64 < -2^53), quote(i64 %in% c(1, 0)), quote(i64 + 1 > 5), quote(i64 == 9007199254740993), quote(is.na(i64)),
               quote(i64 >= 2^63), quote(i64 < 2^63), quote(i64 <= -2^63), quote(i64 > 0.5), quote(i64 == 1e19))) {
  r <- try1(eval(bquote(lake_read(tbl, columns = c("i64", "a"), int64 = "integer64", filter = .(e)))))
  cat(deparse(e), ":", if (is_err(r)) r$msg else paste(r$a, collapse = " "), "\n")
}

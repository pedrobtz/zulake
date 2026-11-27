source(file.path(Sys.getenv("W"), "common.R")); suppressPackageStartupMessages(library(bit64))
src <- file.path(FX, "zl-basic"); t0 <- lake_open(src, version = 0); print(lake_schema(t0)[, 1:2]); full <- lake_read(t0); print(full)
cat(grep("add", readLines(file.path(src, "_delta_log/00000000000000000000.json")), value = TRUE), "\n")
mk <- function(pat, rep) {
  dst <- file.path(W, "t/statlog"); unlink(dst, recursive = TRUE); dir.create(dst); file.copy(list.files(src, full.names = TRUE), dst, recursive = TRUE)
  f <- file.path(dst, "_delta_log/00000000000000000000.json"); l <- readLines(f, warn = FALSE); l2 <- sub(pat, rep, l, perl = TRUE); stopifnot(!identical(l, l2)); writeLines(l2, f); dst
}
filters <- alist(id == 1, id >= 1, id < 100, id != 2, is.na(id), !is.na(id), id %in% c(1, 3), !(id %in% 1), id > 2, !(id > 2), id == 3 | is.na(id))
run <- function(label, pat, rep) {
  t <- try1(lake_open(mk(pat, rep), version = 0)); if (is_err(t)) { cat(sprintf("%-46s open ERR %s\n", label, substr(t$msg, 1, 90))); return(invisible()) }
  bad <- character()
  for (e in filters) { a <- try1(eval(bquote(lake_read(t, filter = .(e))))); r <- full[eval(e, full) %in% TRUE, , drop = FALSE]
    if (is_err(a)) bad <- c(bad, paste(deparse(e), "ERR", substr(a$msg, 1, 60))) else if (!setequal(a$id, r$id)) bad <- c(bad, sprintf("%s got {%s} want {%s}", deparse(e), paste(a$id, collapse = ","), paste(r$id, collapse = ","))) }
  f <- try1(suppressWarnings(lake_files(t))); cnt <- try1(lake_count(t))
  cat(sprintf("%-46s count=%-6s %s\n", label, if (is_err(cnt)) "ERR" else format(cnt), if (length(bad)) paste0("\n      ", bad, collapse = "") else "filters ok"))
}
Q <- '\\\\"'
for (v in c("9007199254740993", "3.0", "3e0", "1.5", "-1", "0", "1", "100", "1e19", "null", "true", paste0(Q, "3", Q), "[3]", "{}")) run(paste("numRecords =", v), paste0("(numRecords", Q, ":)[0-9]+"), paste0("\\1", gsub("\\\\", "\\\\\\\\", v)))
for (v in c("3", "1", "2.0", "0.5", "-1", "1e0", "null", "true", paste0(Q, "0", Q), "9007199254740993", "{}")) run(paste("nullCount.id =", v), paste0("(nullCount", Q, ":\\{[^}]*?", Q, "id", Q, ":)[0-9]+"), paste0("\\1", gsub("\\\\", "\\\\\\\\", v)))
for (v in c("1.0", "1e0", "0.5", "1.5", "2", "3", "-0", "+1", "01", "null", "true", "false", paste0(Q, "1", Q), paste0(Q, "a", Q), "1e400", "-1e400", "9223372036854775808", "[1]", "{}")) run(paste("minValues.id =", v), paste0("(minValues", Q, ":\\{[^}]*?", Q, "id", Q, ":)[0-9]+"), paste0("\\1", gsub("\\\\", "\\\\\\\\", v)))
for (v in c("3.0", "3e0", "2.5", "2.9999999999999999999", "null", "true", paste0(Q, "3", Q), "1e400")) run(paste("maxValues.id =", v), paste0("(maxValues", Q, ":\\{[^}]*?", Q, "id", Q, ":)[0-9]+"), paste0("\\1", gsub("\\\\", "\\\\\\\\", v)))

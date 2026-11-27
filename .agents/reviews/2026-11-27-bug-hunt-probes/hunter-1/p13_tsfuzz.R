source(file.path(Sys.getenv("W"), "common.R"))
tbl <- lake_open(file.path(W, "t/tsfuzz")); full <- lake_read(tbl, int64 = "integer64")
cat("rows", nrow(full), "files", nrow(lake_files(tbl)), "\n")
bad <- 0
rep1 <- function(lab, i, got, want) if (!identical(sort(got), sort(want))) { bad <<- bad + 1; if (bad < 40) cat("BAD", lab, "id", full$id[i], full$txt[i], "got", paste(got, collapse = ","), "want", paste(want, collapse = ","), "\n") }
us <- as.character(full$us)
for (i in which(!is.na(full$txt))) {
  tx <- full$txt[i]; same <- full$id[which(full$txt == tx)]
  le <- full$id[which(full$us <= full$us[i])]
  for (col in c("ts", "tn")) {
    v <- tx; e <- bquote(.(as.symbol(col)) == .(v)); rep1(paste(col, "== text"), i, eval(bquote(lake_read(tbl, columns = "id", filter = .(e))))$id, same)
    e <- bquote(.(as.symbol(col)) <= .(v)); rep1(paste(col, "<= text"), i, eval(bquote(lake_read(tbl, columns = "id", filter = .(e))))$id, le)
    e <- bquote(.(as.symbol(col)) > .(v)); rep1(paste(col, "> text"), i, eval(bquote(lake_read(tbl, columns = "id", filter = .(e))))$id, setdiff(full$id[!is.na(full$txt)], le))
    pv <- full[[col]][i]; e <- bquote(.(as.symbol(col)) == .(pv)); rep1(paste(col, "== POSIXct"), i, eval(bquote(lake_read(tbl, columns = "id", filter = .(e))))$id, full$id[which(full[[col]] == pv)])
  }
  # T/Z forms
  v <- paste0(sub(" ", "T", tx), "Z"); rep1("ts == T..Z", i, eval(bquote(lake_read(tbl, columns = "id", filter = ts == .(v))))$id, same)
  v <- paste0(tx, "+00:00"); rep1("ts == +00:00", i, eval(bquote(lake_read(tbl, columns = "id", filter = ts == .(v))))$id, same)
  dv <- format(full$d[i]); if (grepl("^[0-9]{4}-", dv)) { rep1("d == text", i, eval(bquote(lake_read(tbl, columns = "id", filter = d == .(dv))))$id, full$id[which(full$d == full$d[i])])
    dd <- full$d[i]; rep1("d <= Date", i, eval(bquote(lake_read(tbl, columns = "id", filter = d <= .(dd))))$id, full$id[which(full$d <= dd)]) } else cat("date fmt", dv, "\n")
}
cat("bad =", bad, "\n")
# does the double of the row equal us/1e6 rounded once? and distinct µs collide as doubles?
cat("distinct us:", length(unique(us)), " distinct ts doubles:", length(unique(as.numeric(full$ts))), "\n")
print(head(full[order(full$us), c("us", "txt", "d")], 3)); print(format(head(full$ts[order(full$us)], 3), "%Y-%m-%d %H:%M:%OS6"))

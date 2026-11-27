source(file.path(Sys.getenv("W"), "common.R"))
for (name in c("zl-orders", "table_with_ict", "zl-file-times", "simple_table")) {
  p <- file.path(FX, name); tbl <- try1(lake_open(p)); if (is_err(tbl)) { cat(name, tbl$msg, "\n"); next }
  v <- lake_versions(tbl); cat("==", name, "\n"); print(format(v$timestamp, "%Y-%m-%d %H:%M:%OS6")); print(as.numeric(v$timestamp) * 1000, digits = 17)
  bad <- 0
  for (i in seq_len(nrow(v))) {
    t <- v$timestamp[i]
    for (delta in c(0, -0.0004, -0.001, 0.001, 0.0004, -1e-6, 1e-6)) {
      for (tz in c("UTC", "Pacific/Chatham", "America/Sao_Paulo")) {
        tt <- t + delta; attr(tt, "tzone") <- tz
        got <- try1(lake_version(lake_load(tbl, timestamp = tt)))
        ms <- as.numeric(v$timestamp) * 1000
        want <- { h <- round(ms * 1000) <= round(as.numeric(tt) * 1e6); if (any(h)) max(v$version[h]) else min(v$version) }
        if (is_err(got) || got != want) { bad <- bad + 1; cat("MISMATCH", i, delta, tz, if (is_err(got)) got$msg else got, want, "\n") }
      }
    }
    # round trip: version's own timestamp must open that version
    g <- lake_version(lake_load(tbl, timestamp = t)); if (g != v$version[i]) cat("ROUNDTRIP", v$version[i], g, "\n")
    # snapshot timestamp field vs versions
    s <- lake_load(tbl, version = v$version[i])
    if (!identical(as.numeric(s$timestamp), as.numeric(t))) cat("SNAP TS differs", i, "\n")
  }
  cat("bad", bad, "\n")
  for (tt in list(as.POSIXct(NA), as.POSIXct(Inf), as.POSIXct(-Inf), as.POSIXlt(v$timestamp[1]), as.POSIXct(-1e15, origin = "1970-01-01"), as.POSIXct(1e15, origin = "1970-01-01"), rep(v$timestamp[1], 2), v$timestamp[0], as.POSIXct(1e300), structure(1L, class = c("POSIXct","POSIXt")), structure(NA_integer_, class = c("POSIXct","POSIXt")), structure("2025-01-08", class = c("POSIXct","POSIXt")))) {
    r <- try1(lake_version(lake_load(tbl, timestamp = tt))); cat("  ", format(tt)[1], "->", if (is_err(r)) r$msg else r, "\n")
  }
  r <- try1(lake_load(tbl, version = 0, timestamp = v$timestamp[1])); cat("both:", if (is_err(r)) r$msg else "NO ERROR", "\n")
}

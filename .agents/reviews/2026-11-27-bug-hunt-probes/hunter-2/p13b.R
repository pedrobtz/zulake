.libPaths(c("/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/lib", .libPaths()))
suppressPackageStartupMessages(library(zulake))
T <- "/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/hunt-2/t/"
for (n in c("g_s_emptyname", "g_s_noname")) {
  cat("##", n, "\n")
  t <- lake_open(paste0(T, n))
  for (f in c("lake_schema", "lake_files", "lake_read", "lake_count", "lake_summary", "print")) {
    r <- tryCatch({ withCallingHandlers(utils::capture.output(get(f)(t)), error = function(e) { calls <- sys.calls(); cat("   ", f, "trace:", paste(vapply(calls[pmax(1, length(calls) - 6):length(calls)], function(x) deparse(x[[1]])[1], ""), collapse = " > "), "\n") }); "ok" }, error = function(e) paste0("ERR<", class(e)[1], "> ", conditionMessage(e)))
    cat("  ", f, ":", r, "\n")
  }
}

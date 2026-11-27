# usage: Rscript eq.R <tableA> <tableB> [version] -- every inspection result of A against B
.libPaths(c("/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/lib", .libPaths()))
suppressPackageStartupMessages(library(zulake))
args <- commandArgs(TRUE)
v <- if (length(args) > 2) as.numeric(args[3]) else NULL
get <- function(expr) tryCatch(suppressWarnings(expr), error = function(e) paste0("ERROR <", class(e)[1], "> ", conditionMessage(e)))
norm <- function(x, root) {
  if (is.data.frame(x)) { x[] <- lapply(x, norm, root = root); rownames(x) <- NULL; return(x) }
  if (is.list(x)) return(lapply(x, norm, root = root))
  if (is.character(x)) return(gsub(root, "<ROOT>", x, fixed = TRUE))
  x
}
views <- function(p) {
  t <- get(lake_open(p, version = v))
  if (is.character(t)) return(list(open = t))
  root <- normalizePath(p)
  r <- list(
    version = lake_version(t),
    files = get(lake_files(t)), removed = get(lake_removed(t)), txn = get(lake_transactions(t)),
    txn64 = get(lake_transactions(t, int64 = "integer64")),
    domains = get(lake_domains(t)), protocol = get(lake_protocol(t)), metadata = get(lake_metadata(t)),
    schema = get(lake_schema(t)), props = get(lake_properties(t)), count = get(lake_count(t)),
    partitions = get(lake_partitions(t)),
    dv = get(lake_deletion_vectors(t)), read = get({ d <- lake_read(t); if (nrow(d) && ncol(d)) d[do.call(order, unname(lapply(d, function(x) if (is.list(x)) seq_along(x) else x))), , drop = FALSE] else d }),
    raw_files = lapply(t$files$action, function(a) a[order(names(a))]), raw_removed = lapply(t$removed$action, function(a) a[order(names(a))]),
    raw_txn = t$transactions, raw_dom = t$domains)
  norm(r, root)
}
a <- views(args[1]); b <- views(args[2])
for (n in union(names(a), names(b))) {
  e <- all.equal(a[[n]], b[[n]], tolerance = 0)
  if (!isTRUE(e)) { cat("DIFF", n, ":\n"); cat(paste0("   ", utils::head(e, 12)), sep = "\n"); if (is.character(a[[n]])) cat("   A:", a[[n]], "\n"); if (is.character(b[[n]])) cat("   B:", b[[n]], "\n") } else cat("same", n, if (is.character(a[[n]]) && length(a[[n]]) == 1) a[[n]], "\n")
}

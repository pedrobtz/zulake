source("setup.R")
root <- file.path(fixture_dir(), "tables")
log <- new.env(); use(azure_fake(root, log))
t <- lake_open("abfss://lake@acct.dfs.core.windows.net/zl-checkpoint", credentials = cred)
fns <- list(version = lake_version, schema = lake_schema, protocol = lake_protocol, metadata = lake_metadata, properties = lake_properties, files = lake_files, removed = lake_removed, transactions = lake_transactions, domains = lake_domains, history = lake_history, log = lake_log, versions = lake_versions, count = lake_count, count_f = function(t) lake_count(t, footers = TRUE), dv = function(t) lake_deletion_vectors(t, rows = FALSE), changes = function(t) lake_changes(t, 11, 12), print = function(t) capture.output(print(t)))
for (n in names(fns)) { n0 <- length(log$requests); r <- try_(suppressWarnings(fns[[n]](t))); rs <- log$requests[seq_len(length(log$requests) - n0) + n0]
  cat(sprintf("%-10s requests %2d %s %s\n", n, length(rs), if (inherits(r, "condition")) conditionMessage(r) else "", paste(unique(vapply(rs, function(r) if (identical(r$query$comp, "list")) "LIST" else sub(".*/", "", r$path), "")), collapse = " "))) }

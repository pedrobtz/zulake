source(file.path(Sys.getenv("W"), "common.R"))
key <- function(f) paste(f$path, if ("deletion_vector_id" %in% names(f)) f$deletion_vector_id else "", sep = "|")
for (nm in list.files(FX)) {
  t <- try1(lake_open(file.path(FX, nm))); if (is_err(t)) next
  vs <- lake_versions(t)$version; msgs <- character(); n <- 0
  snaps <- lapply(vs, function(v) try1(lake_load(t, version = v))); names(snaps) <- vs
  for (a in vs) for (b in vs[vs >= a]) {
    sa <- snaps[[as.character(a)]]; sb <- snaps[[as.character(b)]]; if (is_err(sa) || is_err(sb)) next
    ch <- try1(lake_changes(t, a, b)); n <- n + 1
    if (is_err(ch)) { msgs <- c(msgs, sprintf("changes(%s,%s) ERR %s", a, b, substr(ch$msg, 1, 70))); next }
    ka <- with(sa$files, paste(path, deletion_vector_id, sep = "|")); kb <- with(sb$files, paste(path, deletion_vector_id, sep = "|"))
    fa <- lake_files(sa, stats = FALSE); fb <- lake_files(sb, stats = FALSE)
    want_add <- fb$path[!kb %in% ka]; want_rm <- fa$path[!ka %in% kb]
    if (!setequal(ch$path[ch$change == "added"], want_add) || sum(ch$change == "added") != length(want_add)) msgs <- c(msgs, sprintf("changes(%s,%s) added %d want %d", a, b, sum(ch$change == "added"), length(want_add)))
    if (!setequal(ch$path[ch$change == "removed"], want_rm) || sum(ch$change == "removed") != length(want_rm)) msgs <- c(msgs, sprintf("changes(%s,%s) removed %d want %d", a, b, sum(ch$change == "removed"), length(want_rm)))
    if (!identical(names(ch)[-1], names(fa))) msgs <- c(msgs, "columns differ from lake_files(stats=FALSE)")
    # same from an older snapshot
    ch2 <- try1(lake_changes(sa, a, b)); if (is_err(ch2) != FALSE && b > a) msgs <- c(msgs, sprintf("from snapshot v%s: changes(%s,%s): %s", a, a, b, substr(ch2$msg, 1, 80)))
    else if (!is_err(ch2) && !identical(ch, ch2)) msgs <- c(msgs, sprintf("snapshot-dependent changes(%s,%s)", a, b))
  }
  # default `to`
  if (length(vs)) { d <- try1(lake_changes(t, vs[1])); e <- try1(lake_changes(t, vs[1], lake_version(t))); if (!identical(d, e)) msgs <- c(msgs, "default to differs") }
  # actions for a version after the snapshot's
  if (length(vs) > 1) { s0 <- snaps[[1]]; if (!is_err(s0)) { r <- try1(lake_actions(s0, max(vs))); r2 <- try1(lake_actions(t, max(vs))); if (!identical(r, r2)) msgs <- c(msgs, paste("actions after snapshot:", if (is_err(r)) substr(r$msg, 1, 60) else "differs")) 
     hv <- try1(lake_history(s0)$version); if (!identical(hv, rev(vs[vs <= lake_version(s0)]))) msgs <- c(msgs, "history versions of old snapshot")
     if (!identical(lake_versions(s0)$version, vs[vs <= lake_version(s0)])) msgs <- c(msgs, "versions of old snapshot") } }
  h <- lake_history(t); if (!identical(h$version, rev(vs))) msgs <- c(msgs, "history != rev(versions)")
  if (!identical(as.numeric(h$timestamp), rev(as.numeric(lake_versions(t)$timestamp)))) msgs <- c(msgs, "history ts != versions ts")
  for (k in c(0, 1, 2, 1000)) if (!identical(lake_history(t, limit = k), utils::head(h, k)) && !(k == 0 && nrow(lake_history(t, limit = 0)) == 0)) msgs <- c(msgs, sprintf("history limit %s != head", k))
  cat(sprintf("%-40s pairs=%-3d %s\n", nm, n, if (length(msgs)) paste0("\n     ", unique(msgs), collapse = "") else "ok"))
}

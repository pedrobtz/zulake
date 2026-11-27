source(file.path(Sys.getenv("W"), "common.R"))
p <- file.path(FX, "zl-orders")
tbl <- lake_open(p)
show <- function(label, e) { r <- try1(e); cat(sprintf("%-55s ", label)); if (is_err(r)) cat("ERR[", r$cls, "]", substr(r$msg, 1, 110), "\n") else { cat(paste(utils::capture.output(str(r, give.attr = FALSE, vec.len = 4))[1:min(3, length(utils::capture.output(str(r))))], collapse = " / "), "\n") } }
vals <- list(`1L` = 1L, `1` = 1, `1.5` = 1.5, `-1` = -1, `0` = 0, big31 = 2^31, big53 = 2^53, Inf_ = Inf, NA_ = NA, NAr = NA_real_, NAi = NA_integer_, `TRUE` = TRUE,
  chr = "1", fac = factor("1"), vec = c(1, 2), zero = numeric(), list = list(1), named = c(a = 1), date = as.Date("2025-01-08"), px = as.POSIXct("2025-01-08 12:00", tz = "UTC"),
  i64 = bit64::as.integer64(1), i64big = bit64::as.integer64("9007199254740993"), i64na = bit64::NA_integer64_, cplx = 1+0i, `1+eps` = 1 + 1e-12, `0.9999999999999999` = 0.9999999999999999)
for (n in names(vals)) { v <- vals[[n]]
  show(paste("open version", n), lake_version(lake_open(p, version = v)))
  show(paste("load version", n), lake_version(lake_load(tbl, version = v)))
  show(paste("actions version", n), nrow(lake_actions(tbl, v)))
  show(paste("changes from", n), nrow(lake_changes(tbl, v)))
  show(paste("changes to", n), nrow(lake_changes(tbl, 0, v)))
  show(paste("history limit", n), nrow(lake_history(tbl, limit = v)))
  show(paste("open timestamp", n), lake_version(lake_open(p, timestamp = v)))
}
print(lake_versions(tbl))

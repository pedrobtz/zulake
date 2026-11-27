.libPaths(c("/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/lib", .libPaths()))
library(zulake)
T <- "/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/hunt-2/t/"
x <- lake_read(lake_open(paste0(T, "pt_ts_nano")))$p; cat("nano micros:", sprintf("%.0f", as.numeric(x) * 1e6), "\n")
x <- lake_read(lake_open(paste0(T, "pt_double"))); cat("-0.0 sign: 1/x =", 1 / x$p[x$id == 2], "\n")
x <- lake_read(lake_open(paste0(T, "pt_bin"))); str(x)
x <- lake_read(lake_open(paste0(T, "pt_float"))); print(x$p, digits = 17)
print(lake_partitions(lake_open(paste0(T, "pt_float"))))

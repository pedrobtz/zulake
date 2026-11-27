H <- "/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt"
.libPaths(c(file.path(H, "lib"), .libPaths()))
suppressMessages(library(zulake))
fixture_dir <- function() file.path(H, "src/tests/testthat/fixtures")
fixture_table <- function(n) file.path(fixture_dir(), "tables", n)
source(file.path(H, "src/tests/testthat/helper-azure.R"))
use <- function(transport) options(zulake.azure_client = zuhttp::zu_client(transport = transport), zulake.azure_endpoint = NULL)
TOKEN <- "SECRETtok3nABCDEFGH12345678"
cred <- function() TOKEN
try_ <- function(expr) tryCatch(expr, error = function(e) e)
show <- function(e) if (inherits(e, "condition")) cat("  <", class(e)[1], "> ", conditionMessage(e), "\n", sep = "") else { cat("  OK: "); str(e, max.level = 1, give.attr = FALSE) }
has_token <- function(x, token = TOKEN) {
  b <- serialize(x, NULL); txt <- paste(capture.output(print(x)), collapse = "\n")
  pcs <- substring(token, 1:(nchar(token) - 7), 8:nchar(token))
  any(vapply(pcs, function(p) length(grepRaw(p, b, fixed = TRUE)) > 0 || grepl(p, txt, fixed = TRUE), NA))
}

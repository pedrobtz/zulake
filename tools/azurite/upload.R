# Uploads every fixture table to Azurite, for test-azure-emulator.R and
# tools/oracle/azurite.py: tests/testthat/fixtures/tables/<table> becomes the
# blobs <table>/... of the container "fixtures", byte for byte, with the
# test token of tests/testthat/helper-azure.R. Run from the package root,
# with Azurite up and ZULAKE_AZURITE_ENDPOINT and ZULAKE_AZURITE_CA set
# (tools/azurite/README.md):
#
#   Rscript tools/azurite/upload.R
source("tests/testthat/helper-azure.R")
if (!nzchar(azurite_endpoint())) {
  stop("set ZULAKE_AZURITE_ENDPOINT (tools/azurite/README.md)", call. = FALSE)
}
tables <- list.files("tests/testthat/fixtures/tables")
tables <- tables[dir.exists(file.path("tests/testthat/fixtures/tables", tables, "_delta_log"))]
for (t in tables) {
  n <- azurite_upload(file.path("tests/testthat/fixtures/tables", t), azurite_container, t)
  cat(t, ":", n, "files\n")
}

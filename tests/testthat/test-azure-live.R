# The live layer of design section 8 (acceptance criterion 4b): one table on
# a real ADLS Gen2 account, read by zulake with a bearer token and compared
# with deltalake 1.7.0 reading the same table (tools/oracle/live.py).
# .github/workflows/azure-live.yaml runs it on dispatch, with the
# repository's secrets; a maintainer can run it locally the same way
# (tools/azurite/README.md, "Live"):
#
#   ZULAKE_AZURE_URI      the table, in any of the three URI forms
#   ZULAKE_AZURE_TOKEN    a token for https://storage.azure.com
#   ZULAKE_AZURE_ANSWERS  optional: deltalake's answers for it (live.py)
#
# Everywhere else, CRAN included, it skips: the variables are unset.

test_that("a table on ADLS Gen2 equals deltalake's reading of the same table", {
  uri <- live_uri()
  token <- Sys.getenv("ZULAKE_AZURE_TOKEN")
  # The token is read when zulake asks for it, so the function holds none.
  credentials <- function() Sys.getenv("ZULAKE_AZURE_TOKEN")
  tbl <- lake_open(uri, credentials = credentials)
  expect_s3_class(tbl, "zulake_table")
  got <- collect_warnings(lake_read(tbl))
  expect_identical(nrow(got$value), as.integer(lake_count(tbl, footers = TRUE)))
  answers <- Sys.getenv("ZULAKE_AZURE_ANSWERS")
  if (nzchar(answers)) {
    local_oracle_answers(answers)
    v <- lake_version(tbl)
    expect_oracle(v, "live", v, "loaded_version")
    expect_oracle(replay_files_frame(tbl, "path"), "live", v, "add_actions")
    skipped <- vapply(Filter(function(w) inherits(w, "zulake_warning_column_skipped"), got$warnings),
                      function(w) w$column, "")
    expect_read_oracle(got$value, "live", v, skipped = skipped)
  }
  # The same table by the other two URI forms.
  for (other in live_uri_forms(uri)) {
    expect_identical(lake_files(lake_open(other, credentials = credentials))$path, lake_files(tbl)$path)
  }
  expect_no_token(tbl, token, "the live snapshot")
  expect_no_token(utils::capture.output(print(tbl)), token, "its print")
  e <- catch_error(lake_open(uri, credentials = function() "not-a-token"), "zulake_error_auth")
  expect_no_token(e, token)
})

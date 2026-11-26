# The emulator layer of design section 8 (D13, acceptance criterion 4a):
# every fixture table uploaded to Azurite, served over HTTPS with
# `--oauth basic`, read by zulake with a bearer token, and compared with
# zulake's own local answers and with deltalake 1.7.0 reading the same
# container (tools/oracle/azurite.py). .github/workflows/azure-emulator.yaml
# sets the environment (helper-azure.R lists it); everywhere else, CRAN
# included, these tests skip, because the variable is unset.

test_that("every fixture on Azurite gives zulake's local snapshot, files, log and read", {
  local_azurite()
  calls <- 0
  token <- function() {
    calls <<- calls + 1
    azurite_token
  }
  opened <- 0
  seen <- 0L
  for (table in fixture_names("tables")) {
    for (version in fixture_log_versions(fixture_table(table))) {
      local <- open_or_class(fixture_table(table), version)
      remote <- open_or_class(azurite_uri(table), version, token)
      opened <- opened + 1
      label <- paste(table, version)
      if (is.character(local)) {
        expect_identical(remote, local, label = label)
        next
      }
      expect_s3_class(remote, "zulake_table")
      want <- snapshot_answers(local)
      got <- snapshot_answers(remote)
      if (!is.null(want$read)) {
        expect_identical(lapply(got$read$warnings, class), lapply(want$read$warnings, class), label = label)
        got$read <- got$read$value
        want$read <- want$read$value
      }
      expect_identical(got, want, label = label)
      seen <- seen + 1L
    }
  }
  expect_gt(seen, 80L)
  # One call per snapshot's backend: Azurite never answered 401.
  expect_identical(calls, opened)
})

test_that("zulake on Azurite agrees with deltalake on the same container", {
  local_azurite()
  answers <- Sys.getenv("ZULAKE_AZURITE_ANSWERS")
  skip_if(!nzchar(answers), "deltalake's Azurite answers are not there (ZULAKE_AZURITE_ANSWERS)")
  # deltalake's local answers first: which cases zulake opens.
  local_cases <- inspect_cases()
  local_oracle_answers(answers)
  seen <- 0L
  for (case in local_cases) {
    label <- paste(case$table, case$version)
    refusal <- oracle_refusal(case$table, case$version)
    if (!is.null(refusal)) {
      # deltalake 1.7.0 lists _delta_log/ recursively on an object store, and
      # simple_table has _delta_log/.tmp/00000000000000000005.json: it then
      # opens no version but the latest there, where it opens all of them
      # from local disk (design section 8). zulake lists the directory alone.
      expect_identical(case$table, "simple_table", label = label)
      expect_identical(refusal$message, "No table version found.", label = label)
      next
    }
    tbl <- lake_open(azurite_uri(case$table), version = case$version, credentials = function() azurite_token)
    expect_oracle(lake_version(tbl), case$table, case$version, "loaded_version")
    expect_oracle(replay_files_frame(tbl, "path"), case$table, case$version, "add_actions")
    expect_oracle(lake_metadata(tbl)$id, case$table, case$version, c("metadata", "id"))
    p <- lake_protocol(tbl)
    expect_oracle(p$version[p$name == "readerVersion"], case$table, case$version, c("protocol", "min_reader_version"))
    expect_oracle(p$version[p$name == "writerVersion"], case$table, case$version, c("protocol", "min_writer_version"))
    if (!all(vapply(tbl$files$action, function(a) is.null(a[["stats"]]), NA))) {
      count <- suppressWarnings(lake_count(tbl))
      if (!is.na(count)) expect_oracle(count, case$table, case$version, "count")
    }
    if (requireNamespace("zuroar", quietly = TRUE) || all(tbl$files$deletion_vector_id == "")) {
      got <- collect_warnings(lake_read(tbl))
      skipped <- vapply(Filter(function(w) inherits(w, "zulake_warning_column_skipped"), got$warnings),
                        function(w) w$column, "")
      expect_read_oracle(got$value, case$table, case$version, skipped = skipped)
    }
    seen <- seen + 1L
  }
  expect_gt(seen, 75L)
})

test_that("the three URI forms read the same table from Azurite", {
  local_azurite()
  tbls <- lapply(c("abfss", "dfs", "blob"), function(form) {
    lake_open(azurite_uri("zl-partitioned", form), credentials = function() azurite_token)
  })
  reads <- lapply(tbls, lake_read)
  expect_identical(reads[[2L]], reads[[1L]])
  expect_identical(reads[[3L]], reads[[1L]])
  expect_identical(reads[[1L]], lake_read(lake_open(fixture_table("zl-partitioned"))))
})

test_that("Azurite's refusal of a token is a classed error without the token", {
  local_azurite()
  for (bad in list(azurite_token_expired, azurite_token_wrong_audience, "not-a-jwt")) {
    calls <- 0
    e <- tryCatch(
      lake_open(azurite_uri("zl-basic"), credentials = function() {
        calls <<- calls + 1
        bad
      }),
      error = function(e) e
    )
    expect_s3_class(e, "zulake_error_auth")
    # Azurite answers 403, not Azure's 401, for a bad token (design D13), so
    # there is no second call.
    expect_identical(e$status, 403L)
    expect_identical(calls, 1)
    expect_no_token(e, bad)
  }
  e <- tryCatch(lake_open(azurite_uri("zl-basic")), error = function(e) e)
  expect_s3_class(e, "zulake_error_auth")
  expect_false(lake_is_table(sprintf("abfss://nosuchcontainer@%s.dfs.core.windows.net/x", azurite_account),
                             credentials = function() azurite_token))
})

test_that("cassettes are recorded from Azurite without the token", {
  local_azurite()
  dir <- Sys.getenv("ZULAKE_RECORD_CASSETTES")
  skip_if(!nzchar(dir), "not recording cassettes (ZULAKE_RECORD_CASSETTES)")
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  for (table in cassette_tables) {
    old <- list.files(dir, pattern = paste0("^", table, "(-range-.*)?[.]rds$"), full.names = TRUE)
    unlink(old)
    withr::with_options(list(zulake.azure_client = zuhttp::zu_client(
      transport = cassette_router(dir, table, "record", tls = zuhttp::zu_tls(ca_extra = Sys.getenv("ZULAKE_AZURITE_CA")))
    )), {
      cassette_session(table)
    })
  }
  files <- list.files(dir, pattern = "[.]rds$", full.names = TRUE)
  expect_gte(length(files), length(cassette_tables) + 2L)
  for (f in files) expect_no_token(readRDS(f), azurite_token)
})

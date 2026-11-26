# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

## Shared conventions

The portfolio’s shared rules (`workflow`, `r-package`, `ci`,
`correctness`, `assurance`) come from the
[r-skills](https://github.com/pedrobtz/r-skills) plugin’s `rules/`,
loaded at session start because of the marker above. Never copy them
here. Where this file and a shared rule disagree, this file wins for
this package. Cloud sessions do not load the plugin and run without
them.

## What this is

`zulake` opens a Delta Lake table where it is stored (Azure Data Lake
Storage Gen2 or Blob Storage, or local disk) and exposes everything the
table’s log records as base data frames: versions, commits, live files
with their partition values, statistics and deletion vectors, schema,
protocol and properties, and the changes between versions. Reading data,
with file pruning by partition and statistics, is the convenience on
top. It is pure R over `zujson`, `qio` and `zuhttp`, with `zuroar`
suggested for deletion vectors. It does not write, run queries, obtain
Azure tokens or support stores other than Azure, and 0.1.0 does not read
Iceberg.

The specification is
[`.agents/design.md`](https://pedrobtz.github.io/zulake/.agents/design.md),
adopted from RFC 0081. It outranks this file: `CLAUDE.md` orients, the
design decides.

## Current state

Scaffolded 2026-11-26 with `create-pkg.sh`. Stage 2 (log replay from
commit 0, local disk only) is in:
[`lake_open()`](https://pedrobtz.github.io/zulake/reference/lake_open.md),
[`lake_is_table()`](https://pedrobtz.github.io/zulake/reference/lake_is_table.md),
[`lake_load()`](https://pedrobtz.github.io/zulake/reference/lake_open.md),
[`lake_version()`](https://pedrobtz.github.io/zulake/reference/lake_open.md).
The roadmap in
[`.agents/roadmap.md`](https://pedrobtz.github.io/zulake/.agents/roadmap.md)
takes it to v0.1.0. 0.1.0 waits for `zuhttp` on CRAN and for `zuroar`
0.1.0 (design §9); local log replay, inspection and reading are built on
local fixtures first.

## Versions and dependents

`v0.1.0` issue: created by `pkg-roadmap`. Sibling packages that will
depend on this one: `zugodb`, through an extension that registers a
`delta` format (design §3).

## Commands

The shared commands, plus the suite as CI runs it (shuffled, seed
printed, against the installed package):

``` sh
R CMD INSTALL . && Rscript tools/ci-run-tests.R
ZULAKE_TEST_SEED=<seed> Rscript tools/ci-run-tests.R   # replay an order
```

Fixtures and oracle (uv 0.7.11; the order matters, PROVENANCE.md has
it):

``` sh
Rscript tools/fixtures/hostile.R                                   # hostile logs
(cd tools/oracle && uv run --frozen python ../fixtures/pack.py)    # repack the tar
(cd tools/oracle && uv run --frozen python answers.py)             # deltalake answers
```

## Architecture

See `.agents/design.md` for the why. There is no native layer: no
`src/`, by design (D1).

- `R/storage.R`: the internal storage interface (`list`, `get`,
  `get_range`, `head` over paths relative to the table root) and its
  local backend; `storage_for()` picks one from the URI.
- `R/log.R`: what a `_delta_log/` listing holds (`log_entries()`), JSON
  log files through `zujson`, `_last_checkpoint`.
- `R/replay.R`: the replay plan (commits, log compaction files) and the
  reconciliation of actions into a state.
- `R/protocol.R`: the reader-feature gate (D7) and partition-value
  checks.
- `R/timestamp.R`: commit times and time travel by timestamp.
- `R/open.R`: the exported functions and `snapshot_build()`, which
  documents the snapshot’s fields.
- `R/conditions.R`: `zulake_abort()` and the `zulake_error_*` classes.

## Invariants that are easy to break

- **No compiled code** (D1). The log is JSON and Parquet, which `zujson`
  and `qio` read; adding `src/` changes the package’s CI and CRAN
  profile.
- **`zulake` never imports `zugodb`** (D6). `zugodb` calls `zulake`; the
  reverse makes a dependency cycle.
- **The bearer token never leaves the request.** It is not stored in a
  snapshot, printed, or included in an error or a recorded cassette (D4,
  acceptance criterion 4). A leak here is a credential leak.
- **Unknown or unsupported reader features are refused by name before
  any data is read** (D7). Ignoring `columnMapping` in `id` mode or
  deletion vectors returns wrong rows silently.
- **Statistics only decide what is downloaded.** A file is pruned only
  on “cannot match”; the whole filter is then applied to rows, so a read
  is exact whatever the statistics say (design §6).
- **Names are for a table, not for Delta** (D11). The `lake_` functions,
  the snapshot class and the data frames they return must take Iceberg
  later without renaming.

## Testing

`tests/testthat.R` runs every file with `shuffle = TRUE` after printing
its seed, under R CMD check and covr alike; `tools/ci-run-tests.R` runs
the same file from the source tree. The shuffle reorders every top-level
expression of a test file, so shared functions go in `helper-*.R`, never
at file scope. Fixtures (Stage 1, design §8): 26 Delta tables (14 copied
from `delta-rs`, Apache-2.0; 2 changed from them; 10 `zl-*` written with
`deltalake` 1.7.0) and 8 hostile logs, listed in
`tests/testthat/fixtures/PROVENANCE.md`. They ship packed in
`tests/testthat/fixtures/delta-fixtures.tar`, because Delta paths pass
the 100 bytes a package tarball allows; the unpacked `tables/` and
`hostile/` trees are in git only (`.Rbuildignore`), and are what you
edit. `deltalake` 1.7.0’s answers for every table and version are in
`tests/testthat/fixtures/answers/` (fields and encoding in
`tools/oracle/README.md`). Tests reach them through `helper-oracle.R`:
`fixture_table(name)`, `local_fixture_copy(name)`,
`oracle_field(table, version, field)`, `oracle_refusal()` and
`expect_oracle(actual, table, version, field)`. Never edit an answer by
hand, and never edit a tree without repacking (see Commands). A live
Azure suite gated on `ZULAKE_AZURE_URI` comes in Stage 6.

## Continuous integration

`R-CMD-check.yaml` calls r-actions `r-cmd-check.yml@v1`; `coverage.yaml`
calls r-actions `coverage.yml@v1` (badge on `gh-pages`); `pkgdown.yaml`
builds and deploys the site. `cran-release.yaml` calls r-actions
`cran-release.yml@v1` when `CRAN-SUBMISSION` is pushed: it tags the
submitted commit, creates the GitHub release and opens the `.9000` bump.
So `CRAN-SUBMISSION` is committed, not ignored. `assurance.yaml` calls
r-actions `assurance.yml@v1` with `ungated-jobs: fail` on
`.agents/assurance.md`. The R-CMD-check caller adds Windows R-devel to
the full profile’s runners and runs no container on a quick run (no
`src/`; the full profile runs them). `oracle.yaml` is the package’s own
workflow: it regenerates the `deltalake` answers, the hostile logs and
the fixture tar, and fails on any diff. It runs on dispatch and on pull
requests touching `tools/oracle/`, `tools/fixtures/` or the fixtures (a
`paths` filter, which `assurance.yml` counts as gated).

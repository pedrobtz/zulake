# CLAUDE.md

<!-- markdownlint-disable-next-line MD013 -->
This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Shared conventions

<!-- r-skills: shared-rules -->

The portfolio's shared rules (`workflow`, `r-package`, `ci`, `correctness`,
`assurance`) come from the [r-skills](https://github.com/pedrobtz/r-skills)
plugin's `rules/`, loaded at session start because of the marker above. Never
copy them here. Where this file and a shared rule disagree, this file wins for
this package. Cloud sessions do not load the plugin and run without them.

## What this is

`zulake` opens a Delta Lake table where it is stored (Azure Data Lake Storage
Gen2 or Blob Storage, or local disk) and exposes everything the table's log
records as base data frames: versions, commits, live files with their
partition values, statistics and deletion vectors, schema, protocol and
properties, and the changes between versions. Reading data, with file pruning
by partition and statistics, is the convenience on top. It is pure R over
`zujson`, `qio` and `zuhttp`, with `zuroar` suggested for deletion vectors. It
does not write, run queries, obtain Azure tokens or support stores other than
Azure, and 0.1.0 does not read Iceberg.

The specification is [`.agents/design.md`](.agents/design.md), adopted from
RFC 0081. It outranks this file: `CLAUDE.md` orients, the design decides.

## Current state

Scaffolded 2026-11-26 with `create-pkg.sh`; no functionality yet. The roadmap
in [`.agents/roadmap.md`](.agents/roadmap.md) takes it to v0.1.0. 0.1.0 waits
for `zuhttp` on CRAN and for `zuroar` 0.1.0 (design §9); local log replay,
inspection and reading are built on local fixtures first.

## Versions and dependents

`v0.1.0` issue: created by `pkg-roadmap`. Sibling packages that will depend
on this one: `zugodb`, through an extension that registers a `delta` format
(design §3).

## Commands

The shared commands, plus the suite as CI runs it (shuffled, seed printed,
against the installed package):

```sh
R CMD INSTALL . && Rscript tools/ci-run-tests.R
ZULAKE_TEST_SEED=<seed> Rscript tools/ci-run-tests.R   # replay an order
```

## Architecture

To be written as stages land; see `.agents/design.md`. There is no native
layer: no `src/`, by design (D1).

## Invariants that are easy to break

- **No compiled code** (D1). The log is JSON and Parquet, which `zujson` and
  `qio` read; adding `src/` changes the package's CI and CRAN profile.
- **`zulake` never imports `zugodb`** (D6). `zugodb` calls `zulake`; the
  reverse makes a dependency cycle.
- **The bearer token never leaves the request.** It is not stored in a
  snapshot, printed, or included in an error or a recorded cassette (D4,
  acceptance criterion 4). A leak here is a credential leak.
- **Unknown or unsupported reader features are refused by name before any
  data is read** (D7). Ignoring `columnMapping` in `id` mode or deletion
  vectors returns wrong rows silently.
- **Statistics only decide what is downloaded.** A file is pruned only on
  "cannot match"; the whole filter is then applied to rows, so a read is
  exact whatever the statistics say (design §6).
- **Names are for a table, not for Delta** (D11). The `lake_` functions, the
  snapshot class and the data frames they return must take Iceberg later
  without renaming.

## Testing

`tests/testthat.R` runs every file with `shuffle = TRUE` after printing its
seed, under R CMD check and covr alike; `tools/ci-run-tests.R` runs the same
file from the source tree. The shuffle reorders every top-level expression of
a test file, so shared functions go in `helper-*.R`, never at file scope.
No conformance suite or fixtures yet. The design (§8)
plans DAT and `delta-rs` fixtures, `deltalake` 1.7.0 as the oracle in a
development-only workflow, and a live Azure suite gated on
`ZULAKE_AZURE_URI`.

## Continuous integration

`R-CMD-check.yaml` calls r-actions `r-cmd-check.yml@v1`; `coverage.yaml`
calls r-actions `coverage.yml@v1` (badge on `gh-pages`); `pkgdown.yaml`
builds and deploys the site. `cran-release.yaml` calls r-actions
`cran-release.yml@v1` when `CRAN-SUBMISSION` is pushed: it tags the submitted
commit, creates the GitHub release and opens the `.9000` bump. So
`CRAN-SUBMISSION` is committed, not ignored. `assurance.yaml` calls
r-actions `assurance.yml@v1` with `ungated-jobs: fail` on
`.agents/assurance.md`. The R-CMD-check caller adds Windows R-devel to the
full profile's runners and runs no container on a quick run (no `src/`; the
full profile runs them). No package-specific workflows yet.

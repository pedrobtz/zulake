# zulake: roadmap

Status: draft 2026-11-26. Implements [design.md](design.md).
Target: v0.1.0, the first CRAN release.
Tracking: [v0.1.0 (#1)](https://github.com/pedrobtz/zulake/issues/1), with one
sub-issue per stage;
[CRAN-submission (#14)](https://github.com/pedrobtz/zulake/issues/14).

The order, moved here from the design's §9: everything that needs only
local fixtures first, then the Azure backend. `zuhttp` and `zuroar` are
not on CRAN (checked 2026-11-26), so Stages 5 and 6 use them through
`Remotes:`, and [Stage 10](#stage-10--v010-readiness) cannot finish until
both are released ([D5](design.md#10-decisions); `zuroar` 0.1.0 waits on
[pedrobtz/zuroar#64](https://github.com/pedrobtz/zuroar/issues/64)).

## Stages

<!-- markdownlint-disable MD013 -->
| Stage | Title | CI | Issue | Pull request | Done |
| --- | --- | --- | --- | --- | --- |
| 0 | [Package identity](#stage-0--package-identity) | quick | [#2](https://github.com/pedrobtz/zulake/issues/2) | | |
| 1 | [Fixtures and oracle](#stage-1--fixtures-and-oracle) | quick | [#3](https://github.com/pedrobtz/zulake/issues/3) | | |
| 2 | [Log replay](#stage-2--log-replay) | quick | [#4](https://github.com/pedrobtz/zulake/issues/4) | | |
| 3 | [Inspection](#stage-3--inspection) | quick | [#5](https://github.com/pedrobtz/zulake/issues/5) | | |
| 4 | [Reading and pruning](#stage-4--reading-and-pruning) | quick | [#6](https://github.com/pedrobtz/zulake/issues/6) | | |
| 5 | [Deletion vectors and column mapping](#stage-5--deletion-vectors-and-column-mapping) | full | [#7](https://github.com/pedrobtz/zulake/issues/7) | | |
| 6 | [Azure backend](#stage-6--azure-backend) | quick | [#8](https://github.com/pedrobtz/zulake/issues/8) | | |
| 7 | [Documentation](#stage-7--documentation) | quick | [#9](https://github.com/pedrobtz/zulake/issues/9) | | |
| 8 | [Assurance](#stage-8--assurance) | quick | [#10](https://github.com/pedrobtz/zulake/issues/10) | | |
| 9 | [Full CI](#stage-9--full-ci) | full | [#11](https://github.com/pedrobtz/zulake/issues/11) | | |
| 10 | [v0.1.0 readiness](#stage-10--v010-readiness) | full | [#12](https://github.com/pedrobtz/zulake/issues/12) | | |
| 11 | [Review](#stage-11--review) | full | [#13](https://github.com/pedrobtz/zulake/issues/13) | | |
<!-- markdownlint-enable MD013 -->

## Stage 0 — Package identity

**Issue.** [#2](https://github.com/pedrobtz/zulake/issues/2), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zulake/issues/1).

**CI.** `quick`.

**Goal.** The package has its real identity, its CI economy and an
assurance file, so every later stage starts on a shuffled, measured suite
whose quick run finishes in under five minutes.

**Work.**

- `DESCRIPTION`: real Title and Description from [§1](design.md#1-what-zulake-is),
  `Authors@R` with `aut`, `cre`, `cph`; `Version: 0.0.0.9000`. `NEWS.md`
  loses the scaffold's "Initial CRAN submission" bullet.
- `.Rbuildignore` checked against the template's list (already complete
  at scaffold).
- `R-CMD-check.yaml`: add `{"os": "windows-latest", "r": "devel"}` to
  `runners`.
- `.agents/assurance.md` from `templates/assurance.md`, kinds
  `untrusted-input` and `spec`. `fuzz` and `fuzz-reach` are
  `n/a: pure R; r-actions fuzz.yml fuzzes C through libFuzzer, and the
  hostile-log tests and filter property test carry the oracle`. Boundaries
  and Limits rows start as `gap #<issue>` and are filled by the stages
  below. `assurance.yaml` caller with `ungated-jobs: fail`.
- Test runner: `tools/ci-run-tests.R` that runs the suite shuffled, prints
  its seed, and runs under coverage; the coverage caller uses it.
- Labels `full-ci`, `ci:minimal` and `ci:docs` created.
- No `gctorture`, `platforms.yml` or native callers: there is no `src/`
  ([D1](design.md#10-decisions)).

**Tests.**

- Shuffled runner: a run prints its seed, and rerunning with that seed
  repeats the order, in `tools/ci-run-tests.R` (checked in the CI log).

**Exit criteria.**

- `R CMD check` passes on the quick r-actions profile, and every check of
  the pull request's quick run finished in under five minutes.
- `assurance.yml` is green with `ungated-jobs: fail`.
- The CI log of the pull request shows the test seed.

**Design.** [§1](design.md#1-what-zulake-is), [D1](design.md#10-decisions).

## Stage 1 — Fixtures and oracle

**Issue.** [#3](https://github.com/pedrobtz/zulake/issues/3), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zulake/issues/1).

**CI.** `quick`.

**Goal.** Every later stage has its corpus and an oracle that knows the
answer: Delta tables on disk and `deltalake` 1.7.0's answers for each,
committed, so the R tests compare without Python.

**Work.**

- Fixture tables from the DAT reader tables and `delta-rs`'s
  `crates/test/tests/data`, once their licences allow it (Q3), copied to
  `tests/testthat/fixtures/tables/` with a `PROVENANCE.md` recording
  source, commit and generating writer per table. Kept small enough for the
  CRAN tarball; the rest stays outside it.
- Hostile-log fixtures generated by `tools/fixtures/hostile.R` from the
  good tables: truncated and corrupt commits, a missing checkpoint part, a
  `_last_checkpoint` past the log, a bad deletion-vector checksum, a wrong
  magic number, a partition value of the wrong type.
- The oracle harness, `tools/oracle/answers.py`, run with `uv` against
  `deltalake==1.7.0`. For each fixture and version it writes
  `tests/testthat/fixtures/answers/<table>/<version>.json`: version,
  history, schema, protocol, metadata, live add actions with partition
  values and stats, count, deletion-vector row indexes, the parsed actions
  of every commit, and the full table read. It observes everything
  `deltalake` exposes for reading; it cannot see the log listing order,
  which Stage 2 checks against the directory itself.
- `oracle.yaml`, the package's own workflow, regenerates the answers and
  fails on any diff. Triggered on dispatch and on pull requests that touch
  `tools/oracle/` or the fixtures (a `paths` filter, which `assurance.yml`
  accepts as gated).
- `tests/testthat/helper-oracle.R`: `expect_oracle(actual, table, version,
  field)`.

**Tests.**

- Harness: every fixture table has an answer file for each of its versions,
  and each answer file names the `deltalake` version, in
  `test-fixtures.R`.
- `expect_oracle()`: fails on one changed value in a known answer, in
  `test-fixtures.R`.

**Exit criteria.**

- Q3 answered in the design, and only licence-compatible tables committed.
- `oracle.yaml` green on dispatch: the regenerated answers equal the
  committed ones.
- Both `**Tests.**` lines exist and were seen to fail.

**Design.** [§8](design.md#8-testing-and-validation).

## Stage 2 — Log replay

**Issue.** [#4](https://github.com/pedrobtz/zulake/issues/4), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zulake/issues/1).

**CI.** `quick`.

**Goal.** `lake_open()` on a local path builds the snapshot the protocol
prescribes, at the latest version, a version or a timestamp, and refuses
what it cannot read by name.

**Work.**

- The internal storage interface of [§4.1](design.md#41-storage) with its
  local backend.
- Log replay of [§4.2](design.md#42-log-replay): `_last_checkpoint`,
  listing, commits through `zujson`, classic, multi-part and V2
  checkpoints and sidecars through `qio`, log compaction files, and the
  reconciliation rules.
- `lake_open()`, `lake_is_table()`, `lake_load()`, `lake_version()`; the
  `zulake_table` class records its format ([D11](design.md#10-decisions)).
- The reader-feature gate of [D7](design.md#10-decisions), with classed
  `zulake_error` conditions naming the feature.
- `Imports: zujson, qio`.

**Tests.**

- Live add actions at every version of every fixture: `deltalake` answers,
  in `test-replay.R`.
- Version from timestamp, with and without `inCommitTimestamp`: `deltalake`
  `load_as_version()` answers, in `test-replay.R`.
- Checkpoint kinds (classic, multi-part, V2 with sidecars): replay from the
  checkpoint equals replay from commit 0 on the same table, and both equal
  `deltalake`, in `test-replay.R`.
- `(path, deletionVector.uniqueId)` key: a file rewritten with a new
  deletion vector is one live row, against `deltalake`, in `test-replay.R`.
- Each hostile-log fixture: a classed `zulake_error`, and no snapshot
  object is returned, in `test-hostile.R`.
- Unsupported features (`columnMapping` `id` mode, `catalogManaged`, an
  unknown name): refused by name before any data file is read, in
  `test-protocol.R`.
- Log listing: the versions found equal the `_delta_log/` directory
  listing, in `test-replay.R`.

**Exit criteria.**

- `R CMD check` passes on the quick r-actions profile.
- Every `**Tests.**` line exists, compares against the named oracle, and
  was seen to fail.
- `.agents/assurance.md` has Boundaries rows for the commit log, the
  checkpoints and the reader-feature gate, each naming its test.

**Design.** [§4.1](design.md#41-storage), [§4.2](design.md#42-log-replay),
[D7](design.md#10-decisions), [D11](design.md#10-decisions).

## Stage 3 — Inspection

**Issue.** [#5](https://github.com/pedrobtz/zulake/issues/5), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zulake/issues/1).

**CI.** `quick`.

**Goal.** Every inspection function of [§5](design.md#5-public-r-api-proposed)
returns its base data frame, with the types of [§7](design.md#7-types).

**Work.**

- The table functions (`lake_history()` to `lake_summary()`), the file
  functions except `lake_deletion_vectors()`, and the log functions
  (`lake_log()` to `lake_checkpoints()`).
- `lake_files(filter =)` and `lake_partitions(filter =)` on partition
  columns only; the statistics side of filters comes in Stage 4.
- The `int64` argument, `decimal` statistics kept as text, `timestamp` and
  `timestamp_ntz` as in §7 ([D10](design.md#10-decisions)).
- Print methods that show no credentials (there are none yet; the test is
  set up here and kept).

**Tests.**

- `lake_history()`, `lake_schema()`, `lake_protocol()`,
  `lake_metadata()`, `lake_partitions()`, `lake_count()` (fixtures without
  deletion vectors), `lake_files()`, `lake_transactions()`:
  `deltalake` answers, in `test-inspect.R`.
- `lake_actions()`: the oracle's own parse of each commit file, in
  `test-inspect.R`.
- `lake_changes(from, to)`: the difference of `deltalake`'s file lists at
  the two versions, in `test-inspect.R`.
- `lake_removed()`, `lake_domains()`, `lake_checkpoints()`,
  `lake_log()`: the fixture's commit files and directory, in
  `test-inspect.R`.
- 64-bit values: `2^53 - 1` exact as a double, `2^53` and `2^53 + 1` an
  error unless `int64 = "integer64"`, then exact, in `test-types.R`.
- `decimal` statistics: the JSON text, byte for byte, in `test-types.R`.
- `filter` refusals: an expression outside the pruning subset in
  `lake_files()` is a classed error, in `test-filter.R`.

**Exit criteria.**

- `R CMD check` passes on the quick r-actions profile.
- Every `**Tests.**` line exists, compares against the named oracle, and
  was seen to fail.
- The 2^53 limit has its row in `.agents/assurance.md`.

**Design.** [§5](design.md#5-public-r-api-proposed),
[§5.1](design.md#51-against-deltalake-170), [§7](design.md#7-types).

## Stage 4 — Reading and pruning

**Issue.** [#6](https://github.com/pedrobtz/zulake/issues/6), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zulake/issues/1).

**CI.** `quick`.

**Goal.** `lake_read()` and `lake_walk()` return exactly the table's rows,
downloading only the files a filter cannot rule out.

**Work.**

- Reading of [§4.3](design.md#43-reading): session cache, `qio` reads,
  partition columns added, row filtering, binding; `lake_walk()`.
- Pruning of [§6](design.md#6-pruning-and-filtering): the filter split,
  partition values parsed by Delta type, three-valued evaluation on
  statistics, UTF-8 byte order, truncated string maxima.
- Local values in filters looked up in the calling environment
  ([D8](design.md#10-decisions)).

**Tests.**

- Full reads of every fixture: `deltalake`'s full table read, in
  `test-read.R`.
- Filter property test: for random filters over the fixtures,
  `lake_read(filter = f)` equals the full read subset in R (acceptance 2),
  in `test-filter.R`.
- Pruning never drops a file with a matching row: for each pruned file,
  reading it whole and filtering finds no row, in `test-filter.R`.
- Partition value parsing, per Delta type: `deltalake`'s partition values,
  in `test-filter.R`.
- String statistics: comparisons in UTF-8 byte order, and a truncated
  maximum never treated as exact (hand-built stats on a fixture copy), in
  `test-filter.R`.
- `lake_walk()`: the pieces bound together equal `lake_read()`, in
  `test-read.R`.

**Exit criteria.**

- `R CMD check` passes on the quick r-actions profile.
- Every `**Tests.**` line exists, compares against the named oracle, and
  was seen to fail.
- `.agents/assurance.md` has Boundaries rows for data reading and
  pruning, each naming its test.

**Design.** [§4.3](design.md#43-reading),
[§6](design.md#6-pruning-and-filtering), [D8](design.md#10-decisions).

## Stage 5 — Deletion vectors and column mapping

**Issue.** [#7](https://github.com/pedrobtz/zulake/issues/7), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zulake/issues/1).

**CI.** `full — first Suggests guard (zuroar, a GitHub Remote): nosuggests`.

**Goal.** Tables with deletion vectors, `name`-mode column mapping and
`timestampNtz` read correctly, and no deleted row ever appears.

**Work.**

- Deletion vectors of [§4.4](design.md#44-deletion-vectors): descriptors,
  Z85 inline vectors, UUID-relative and absolute paths, range reads, the
  file format with its CRC-32, `zuroar::roar64_unserialize()`.
- `lake_deletion_vectors()` in the shape Q2 settles; `lake_count()` minus
  deleted rows; reads drop marked rows.
- `columnMapping` in `name` mode and `timestampNtz`.
- `Suggests: zuroar`, `Remotes: pedrobtz/zuroar`, and a classed error
  naming `zuroar` when a table needs it and it is absent.

**Tests.**

- Deletion-vector row indexes: `deltalake` `deletion_vectors()` answers,
  in `test-dv.R`.
- Reads of every deletion-vector fixture: no marked row appears
  (acceptance 3), against `deltalake`'s read, in `test-dv.R`.
- Z85: the ZeroMQ RFC 32 test vector, and round trip of random bytes
  through an independent encoder in the test, in `test-dv.R`.
- Bad CRC-32, wrong magic number, size past the file: classed
  `zulake_error`, no rows returned, in `test-hostile.R`.
- `name`-mode column mapping and `timestampNtz`: `deltalake` reads, in
  `test-read.R`.
- `zuroar` absent: classed error naming it, on the `nosuggests` leg, in
  `test-dv.R`.

**Exit criteria.**

- A full-profile r-actions run green on the pull request (`full-ci`),
  including `nosuggests`.
- Every `**Tests.**` line exists, compares against the named oracle, and
  was seen to fail.
- `.agents/assurance.md` has Boundaries rows for deletion vectors, Z85 and
  column mapping.

**Design.** [§4.4](design.md#44-deletion-vectors),
[D9](design.md#10-decisions).

## Stage 6 — Azure backend

**Issue.** [#8](https://github.com/pedrobtz/zulake/issues/8), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zulake/issues/1).

**CI.** `quick`.

**Goal.** Every function works on `abfss://` and the two `https://` forms
with a caller's bearer token, and the token never leaves the request.

**Work.**

- The Azure backend of [§4.1](design.md#41-storage) over `zuhttp`:
  `List Blobs` with prefix and marker, `Get Blob` with `Range`, the pinned
  `x-ms-version`; the three URI forms; other schemes refused
  ([D3](design.md#10-decisions)).
- `credentials()` called before the first request and once more after a
  `401` ([D4](design.md#10-decisions)); redaction from errors and prints.
- `Imports: zuhttp`, `Remotes: pedrobtz/zuhttp`.
- Cassettes recorded against a real account with tokens redacted, under
  `tests/testthat/fixtures/cassettes/`.
- A live suite, skipped unless `ZULAKE_AZURE_URI` and a token are set,
  and `azure-live.yaml`, the package's own workflow, running it on
  dispatch with repository secrets.

**Tests.**

- Requests: the bytes `zuhttp`'s cassette transport received (method,
  path, query, `Range`, `Authorization`, `x-ms-version`), including
  `List Blobs` pagination across a marker, in `test-azure.R`.
- `401`: `credentials()` called exactly twice, then a classed error, with
  `zu_mock_transport`, in `test-azure.R`.
- Token absence: the token string appears in no print, error message,
  condition field, serialized snapshot or cassette, in `test-azure.R`.
- URI forms: all three resolve to the same requests; `s3://`, `gs://` and
  others are refused, in `test-azure.R`.
- Live: the snapshot and full read of a table on ADLS Gen2 equal
  `deltalake`'s on the same table (acceptance 4), in `test-azure-live.R`.

**Exit criteria.**

- `R CMD check` passes on the quick r-actions profile.
- `azure-live.yaml` green on a dispatched run.
- Every `**Tests.**` line exists, compares against the named oracle, and
  was seen to fail.
- `.agents/assurance.md` has the Azure Blob REST boundary row.

**Design.** [§4.1](design.md#41-storage), [D3](design.md#10-decisions) to
[D5](design.md#10-decisions).

## Stage 7 — Documentation

**Issue.** [#9](https://github.com/pedrobtz/zulake/issues/9), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zulake/issues/1).

**CI.** `quick`.

**Goal.** The README and the Get started vignette run on a small table the
package ships, so users and CRAN see real output.

**Work.**

- A small example table in `inst/extdata/orders/`, built from one of the
  licence-compatible fixtures (a design decision to record before the
  stage starts).
- `vignettes/zulake.Rmd` switched to `eval = TRUE` on that table, through
  `pkg-docs`; the README's example the same.
- Every exported function has an example that runs on it.

**Tests.**

- Example table: `lake_open()` on it equals the `deltalake` answers of the
  fixture it came from, in `test-extdata.R`.

**Exit criteria.**

- `R CMD check` passes on the quick r-actions profile, with the vignette
  evaluated.
- `pkgdown` builds with no warning.

**Design.** [§5](design.md#5-public-r-api-proposed).

## Stage 8 — Assurance

**Issue.** [#10](https://github.com/pedrobtz/zulake/issues/10), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zulake/issues/1).

**CI.** `quick`.

**Goal.** `.agents/assurance.md` meets the shared assurance rules for
`untrusted-input` and `spec` with no untracked gap.

**Work.**

- Every Boundaries and Limits row filled from the tests Stages 2 to 6
  added; `n/a` reasons for `fuzz` and `fuzz-reach` reviewed.
- Coverage gap list read; lines no test checks filed as issues.

**Tests.**

- None new; the stage reads the existing ones.

**Exit criteria.**

- `assurance.yml` green.
- Every remaining `gap #<issue>` closed or moved under "After 0.1.0" with
  a reason.

**Design.** [§8](design.md#8-testing-and-validation).

## Stage 9 — Full CI

**Issue.** [#11](https://github.com/pedrobtz/zulake/issues/11), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zulake/issues/1).

**CI.** `full — closing stage`.

**Goal.** The full r-actions profile is green on the default branch's code.

**Work.**

- Run the full profile (`full-ci`) and fix everything it finds: every
  platform leg including Windows R-devel, `nosuggests`, `nold`,
  cran-special. There is no compiled code, so no gctorture dispatch.

**Tests.**

- None new beyond regressions for what the run finds.

**Exit criteria.**

- A full-profile run green on the pull request, and a dispatched one green
  on the merge commit.

**Design.** None.

## Stage 10 — v0.1.0 readiness

**Issue.** [#12](https://github.com/pedrobtz/zulake/issues/12), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zulake/issues/1).

**CI.** `full — closing stage`.

**Goal.** The package is version 0.1.0 and ready to submit.

**Work.**

- `zuhttp` and `zuroar` on CRAN; `Remotes:` removed
  ([D5](design.md#10-decisions), [D9](design.md#10-decisions)).
- `Version: 0.1.0` and the matching `NEWS.md` heading.
- `cran-comments.md` listing the r-actions CI legs as test environments.
- `urlchecker::url_check()` and `spelling::spell_check_package()` clean.
- *Settings → Actions → General → Allow GitHub Actions to create and approve
  pull requests* turned on, so `cran-release.yaml` can open the
  `0.1.0.9000` bump (it is off as of 2026-11-26).

**Tests.**

- None new.

**Exit criteria.**

- `DESCRIPTION` has no `Remotes:` field.
- A full-profile r-actions run green on the merge commit.

**Design.** [§11](design.md#11-acceptance-criteria-for-v010).

## Stage 11 — Review

**Issue.** [#13](https://github.com/pedrobtz/zulake/issues/13), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zulake/issues/1).

**CI.** `full — closing stage`.

**Goal.** The release candidate has passed a critical review and a CRAN
review, in that order.

**Work.**

- `pkg-critical-review`: its blocking and required findings become
  sub-issues of this stage's issue, fixed together in one pull request.
- `pkg-cran-review`, after those fixes, every FAIL and WARN resolved.

**Tests.**

- Regression tests for each finding fixed.

**Exit criteria.**

- Every blocking and required review issue closed.
- The `pkg-cran-review` table clean.
- `NEWS.md` reflects every user-visible fix.
- A full-profile run green on the default branch, whose head becomes the
  release commit.

**Design.** [§11](design.md#11-acceptance-criteria-for-v010).

## After 0.1.0

- [§2](design.md#2-scope) "After 0.1.0": the change data feed
  (`lake_cdf()`), row-group pruning from Parquet footers, SAS and shared-key
  authentication, Iceberg ([D11](design.md#10-decisions)). Not needed to read
  Delta tables on Azure.
- [§12](design.md#12-open-questions) Q7: `id`-mode column mapping, once `qio`
  reads Parquet field IDs; refused by name until then.
- [§12](design.md#12-open-questions) Q4: caching downloads across sessions;
  0.1.0 caches per session.
- [§12](design.md#12-open-questions) Q6: probing commit names instead of
  listing; listing is correct, only possibly slow.

## Blocking open questions

- [§12](design.md#12-open-questions) Q3 blocks Stage 1: the licences of the
  DAT tables and `delta-rs`'s test data.
- [§12](design.md#12-open-questions) Q2 blocks Stage 5: the shape
  `lake_deletion_vectors()` returns.
- [§12](design.md#12-open-questions) Q5 does not block Stage 6 (cassettes
  and the dispatched live suite carry it), but settles whether CI can run
  the Azure suite without secrets.
- [D5](design.md#10-decisions) and [D9](design.md#10-decisions) block Stage 10:
  `zuhttp` and `zuroar` on CRAN.

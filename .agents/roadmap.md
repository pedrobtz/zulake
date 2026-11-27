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
[pedrobtz/zuroar#64](https://github.com/pedrobtz/zuroar/issues/64)), and a
`qio` that reads nested columns
([D14](design.md#10-decisions), [pedrobtz/qio#73](https://github.com/pedrobtz/qio/issues/73)).
Stage 2b, checkpoints, waits for that `qio` and runs after Stage 7.

## Stages

<!-- markdownlint-disable MD013 -->
| Stage | Title | CI | Issue | Pull request | Done |
| --- | --- | --- | --- | --- | --- |
| 0 | [Package identity](#stage-0--package-identity) | quick | [#2](https://github.com/pedrobtz/zulake/issues/2) | [#21](https://github.com/pedrobtz/zulake/pull/21) | 2026-11-26 |
| 1 | [Fixtures and oracle](#stage-1--fixtures-and-oracle) | quick | [#3](https://github.com/pedrobtz/zulake/issues/3) | [#23](https://github.com/pedrobtz/zulake/pull/23) | 2026-11-26 |
| 2 | [Log replay](#stage-2--log-replay) | quick | [#4](https://github.com/pedrobtz/zulake/issues/4) | [#30](https://github.com/pedrobtz/zulake/pull/30) | 2026-11-26 |
| 3 | [Inspection](#stage-3--inspection) | quick | [#5](https://github.com/pedrobtz/zulake/issues/5) | [#31](https://github.com/pedrobtz/zulake/pull/31) | 2026-11-26 |
| 4 | [Reading and pruning](#stage-4--reading-and-pruning) | quick | [#6](https://github.com/pedrobtz/zulake/issues/6) | [#32](https://github.com/pedrobtz/zulake/pull/32) | 2026-11-26 |
| 5 | [Deletion vectors and column mapping](#stage-5--deletion-vectors-and-column-mapping) | full | [#7](https://github.com/pedrobtz/zulake/issues/7) | [#33](https://github.com/pedrobtz/zulake/pull/33) | 2026-11-26 |
| 6 | [Azure backend](#stage-6--azure-backend) | quick | [#8](https://github.com/pedrobtz/zulake/issues/8) | [#35](https://github.com/pedrobtz/zulake/pull/35) | 2026-11-26 |
| 7 | [Documentation](#stage-7--documentation) | quick | [#9](https://github.com/pedrobtz/zulake/issues/9) | [#36](https://github.com/pedrobtz/zulake/pull/36) | 2026-11-26 |
| 2b | [Checkpoints](#stage-2b--checkpoints) | quick | [#26](https://github.com/pedrobtz/zulake/issues/26) | [#38](https://github.com/pedrobtz/zulake/pull/38) | 2026-11-26 |
| 8 | [Assurance](#stage-8--assurance) | quick | [#10](https://github.com/pedrobtz/zulake/issues/10) | [#40](https://github.com/pedrobtz/zulake/pull/40) | 2026-11-26 |
| 9 | [Full CI](#stage-9--full-ci) | full | [#11](https://github.com/pedrobtz/zulake/issues/11) | [#41](https://github.com/pedrobtz/zulake/pull/41) | 2026-11-26 |
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
  *Tuning (2026-11-26):* `quick-containers: '[]'`. The quick `clang23` leg
  took 11m48s on #15, 10.5 minutes of it building Suggests from source in
  the image; it checks C compiler diagnostics, and there is no `src/`. The
  full profile keeps every container.
- `.agents/assurance.md` from `templates/assurance.md`, kinds
  `untrusted-input` and `spec`. `fuzz` and `fuzz-reach` are
  `n/a: pure R; r-actions fuzz.yml fuzzes C through libFuzzer, and the
  hostile-log tests and filter property test carry the oracle`. Boundaries
  and Limits rows start as `gap #<issue>` and are filled by the stages
  below. `assurance.yaml` caller with `ungated-jobs: fail`.
- Test runner: `tools/ci-run-tests.R` that runs the suite shuffled, prints
  its seed, and runs under coverage; the coverage caller uses it.

  *Deviation (2026-11-26):* r-actions `coverage.yml` takes no runner input
  (`native-run` is for its native job only), and covr runs the installed
  `tests/` directory, where `tools/` is absent. So the shuffle and the
  printed seed live in `tests/testthat.R`, which R CMD check and coverage
  both run, and `tools/ci-run-tests.R` runs that same file from the source
  tree (`ZULAKE_TEST_SEED` replays an order). The seed reaches the CI log
  through check-r-package's testthat output step.
- Labels `full-ci`, `ci:minimal` and `ci:docs` created (and `assurance`,
  for the gap issues #16 to #20).
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

  *Q3 (2026-11-26):* no DAT tables (no licence); 14 `delta-rs` tables
  copied unchanged, 2 changed from them, and 9 `zl-*` tables written with
  `deltalake` 1.7.0's writer for what `delta-rs` lacks (multi-part
  checkpoint, no `_last_checkpoint`, domain metadata, log compaction,
  every type at its edges, an unknown reader feature).

  *Deviation (2026-11-26):* the tables and hostile logs ship packed in
  `tests/testthat/fixtures/delta-fixtures.tar`, not as trees. Their paths
  run past the 100 bytes R CMD check allows in a package tarball and
  Spark leaves hidden `.crc` files, both `--as-cran` NOTEs. The trees stay
  in git (`.Rbuildignore`d) for review, `tools/fixtures/pack.py` packs
  them deterministically, and `oracle.yaml` repacks and diffs.
  `PROVENANCE.md` and the Apache licence text sit beside the tar.
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
prescribes from its commits, at the latest version, a version or a
timestamp, and refuses what it cannot read by name.

Changed 2026-11-26: checkpoints moved to
[Stage 2b](#stage-2b--checkpoints), because `qio` cannot read nested
Parquet yet ([D14](design.md#10-decisions)). Every fixture keeps commit 0,
so Stages 3 to 7 are built on replay from commits.

**Work.**

- The internal storage interface of [§4.1](design.md#41-storage) with its
  local backend.
- Log replay of [§4.2](design.md#42-log-replay) from commit 0:
  `_last_checkpoint` parsed, listing, commits through `zujson`, log
  compaction files, and the reconciliation rules. With `_last_checkpoint`
  present and the commits complete, replay from commit 0; when the log no
  longer reaches commit 0, a classed `zulake_error_checkpoint_unreadable`.
- `lake_open()`, `lake_is_table()`, `lake_load()`, `lake_version()`; the
  `zulake_table` class records its format ([D11](design.md#10-decisions)).
- The reader-feature gate of [D7](design.md#10-decisions), with classed
  `zulake_error` conditions naming the feature.
- `Imports: zujson`; `qio` stays in Suggests until Stage 4 reads data.

  *Added (2026-11-26):* the `catalogManaged` refusal needed a fixture, so
  `zl-catalog-managed` (commit 1 upgrades to `catalogManaged` with
  in-commit timestamps, as the protocol requires) was written with
  `tools/fixtures/generate.py`, its answers with `tools/oracle`.

**Tests.**

- Live add actions at every version of every fixture: `deltalake` answers,
  in `test-replay.R`.
- Version from timestamp, with and without `inCommitTimestamp`: `deltalake`
  `load_as_version()` answers, in `test-replay.R`.
- Log without commit 0 (a fixture copy with the early commits removed):
  `zulake_error_checkpoint_unreadable`, no snapshot returned, in
  `test-replay.R`.
- `(path, deletionVector.uniqueId)` key: a file rewritten with a new
  deletion vector is one live row, against `deltalake`, in `test-replay.R`.
- Each hostile-log fixture that needs no checkpoint (truncated and
  corrupt commits, a partition value of the wrong type): a classed
  `zulake_error`, and no snapshot object is returned, in
  `test-hostile.R`.
- Unsupported features (`columnMapping` `id` mode, `catalogManaged`, an
  unknown name): refused by name before any data file is read, in
  `test-protocol.R`.
- Log listing: the versions found equal the `_delta_log/` directory
  listing, in `test-replay.R`.

**Exit criteria.**

- `R CMD check` passes on the quick r-actions profile.
- Every `**Tests.**` line exists, compares against the named oracle, and
  was seen to fail.
- `.agents/assurance.md` has Boundaries rows for the commit log and the
  reader-feature gate, each naming its test.

**Design.** [§4.1](design.md#41-storage), [§4.2](design.md#42-log-replay),
[D7](design.md#10-decisions), [D11](design.md#10-decisions),
[D14](design.md#10-decisions).

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

  *Added (2026-11-26):* the D7 amendment: `vacuumProtocolCheck` accepted
  (fixture `zl-vacuum-protocol-check`), `typeWidening`, `variantType`,
  `variantShredding` and their `-preview` names refused by name,
  `writerFeatures` never a reason to refuse; and `lake_count()` without
  statistics is `NA` with `zulake_warning_count_unknown`, never a partial
  sum ([§5](design.md#5-public-r-api-proposed)). Deletion vector
  cardinalities come from the log, so `lake_count()` subtracts them here.

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
- *Added (2026-11-26):* `lake_count()` where a live file has no
  `numRecords`: `NA` and a warning counting the files that `deltalake`'s
  add actions give null `num_records`, and explicitly not `deltalake`'s 0
  on `simple_table` at version 0; deletion-vector fixtures: `deltalake`'s
  count, in `test-inspect.R`.
- *Added (2026-11-26):* `vacuumProtocolCheck` opens (`deltalake` opens
  `zl-vacuum-protocol-check` too); writer-only features never refuse, in
  `test-protocol.R`.
- *Added (2026-11-26):* partition filters: for seeded random filters, the
  files kept equal R's evaluation of the filter on `deltalake`'s partition
  values, in `test-filter.R`.
- *Added (2026-11-26):* `print()`: format, uri, version, files and
  records, and no credentials, in `test-inspect.R`.

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
- `Imports: qio`.
- `lake_count(tbl, footers = TRUE)` reads the row count of each live file
  without `numRecords` from its Parquet footer (added 2026-11-26, design
  [§5](design.md#5-public-r-api-proposed)).
- Columns `qio` cannot return, found from `qio::read_plan()`
  ([§7](design.md#7-types), [D14](design.md#10-decisions)): with
  `columns = NULL`, left out with a `zulake_warning_column_skipped` naming
  each; named in `columns`, a classed error.

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
- `lake_count(footers = TRUE)` on the fixtures without statistics
  (`simple_table`, `delta-0.8.0-*`): the row count of `deltalake`'s
  committed full read, in `test-read.R`.
- A table with a nested data column, read with `columns = NULL`: the flat
  columns equal `deltalake`'s, and one `zulake_warning_column_skipped`
  names each nested column; the same column named in `columns`: a classed
  error naming it, in `test-read.R`.

**Exit criteria.**

- `R CMD check` passes on the quick r-actions profile.
- Every `**Tests.**` line exists, compares against the named oracle, and
  was seen to fail.
- `.agents/assurance.md` has Boundaries rows for data reading and
  pruning, each naming its test.

**Deviations (2026-11-26).**

- `lake_read()` and `lake_walk()` refuse, until Stage 5, a snapshot with
  live deletion vectors (decided for this stage) and one that maps column
  names (`columnMapping`, the same rule: Stage 5 owns column mapping on
  rows), with `zulake_error_unsupported_feature`. So the full-read test
  covers every fixture version without either, and asserts the refusal on
  the others.
- `lake_read()` and `lake_walk()` take `int64`, as every function that
  returns 64-bit values from the log does (design §5): a `long` partition
  column is one.
- Decisions from the 2026-11-26 review of this stage (nested columns,
  decimals, the exact comparator, 64-bit statistics, `footers = TRUE`,
  deletion vectors refused until Stage 5) are in design §4.3, §5, §6 and
  §7.

**Correction (2026-11-26, after merge; made in Stage 5's pull request).**
Settled by the coordinator on a design adviser's recommendation, under the
maintainer's rule for open questions: a filter is row-wise by construction
(design §5, §6, D8 reworded). Stage 4 let any call filter rows per file, so
`x == max(x)` saw one file at a time while `year == max(year)` on a
partition column pruned with the table's maximum, and a length-1 result
(`any(x > 3)`) was accepted. Now the row-wise functions of §5 and two-column
comparisons filter rows (never pruning, also on partition columns), and
every other call with a column inside is a `zulake_error_filter` in
`lake_read()`, `lake_walk()`, `lake_files()` and `lake_partitions()`.
Unreleased, so no deprecation. Tests: the property test draws from the
row-wise list; file-layout invariance (1 file against 2, 7 and 20);
refusals on a multi-file fixture; shadowing of `nchar` by the caller, in
`test-filter.R`.

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
- `lake_deletion_vectors()` in the shape of
  [D12](design.md#10-decisions); reads drop marked rows, in
  `read_piece()` between the read and the row filter, and Stage 4's
  refusal of deletion vectors and column mapping in `read_refusals()`
  goes. (`lake_count()` already subtracts each descriptor's
  `cardinality`, from Stage 3.)
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

**Deviations (2026-11-26).**

- The `nosuggests` test of `zuroar`'s absence is `tests/zuroar-absent.R`,
  a base-R script, not a `test-dv.R` test: the `nosuggests` image has no
  testthat, so no `test-dv.R` test can run there. It checks only where
  `zuroar` is absent; `test-dv.R` checks the same on every leg with
  `zuroar_available()` mocked. The R-CMD-check caller now passes
  `nosuggests: true` (r-actions runs the job only when asked).
- The `name`-mode column-mapping and `timestampNtz` tests are in
  `test-read.R` as listed; `timestampNtz` has one fixture (`zl-types`),
  since `column_mapping` has no such column.
- The protocol's own inline Example 3 is in Delta's "native" format
  (magic 1681511376), which its format section does not define, so it is
  tested as refused (design §4.4), and its Z85 decoding is checked against
  the example's rows through a 32-bit bitmap.
- Begins with the 2026-11-26 Stage 4 correction (filters row-wise by
  construction), recorded under Stage 4.
- The first full-profile run (on this pull request; Stages 0 to 4 ran
  quick only) found failures from earlier stages, fixed here because this
  stage merges on the full profile: a Windows drive path (`C:/...`) in an
  `add` action was taken as relative (`is_absolute_path()`, Stage 4); and
  in the tests, a test-file path with backslashes written into code, a
  `for ()` over Dates (R before 4.6 drops the class), and `zujson`'s
  parse of `0.12345678901234567` on macOS, which differs from R's in the
  last bit, compared with R's. Behind the Windows timestamp failures was a
  product bug: `mtime_ms()` read whole-millisecond commit times 1 ms early
  on Windows (R reads Windows file times up to about 1 µs low), fixed by
  rounding to 10 µs before truncating (design §4.2); the tests set commit
  times half a millisecond on, since `Sys.setFileTime()` truncates to
  milliseconds there.

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
- First, the spike of [D13](design.md#10-decisions): Azurite over HTTPS
  with `--oauth basic`, a bearer token, `List Blobs` and a ranged
  `Get Blob` through `zuhttp`. If it fails, stop: the stage needs a real
  account.
- The request fake of [§8](design.md#8-testing-and-validation): a
  `zu_mock_transport()` that serves the local fixtures and records every
  request.
- `azure-emulator.yaml`, the package's own workflow, gated per `ci.md`:
  fixtures uploaded to Azurite, read by `zulake` and by `deltalake`.
- Cassettes recorded from that Azurite run with tokens redacted, under
  `tests/testthat/fixtures/cassettes/`, one per ranged request until
  pedrobtz/zuhttp#353 is fixed.
- The internal option `zulake.azure_endpoint` for Azurite's path-style
  URLs.
- A live suite, skipped unless `ZULAKE_AZURE_URI` and a token are set,
  and `azure-live.yaml`, the package's own workflow, running it on
  dispatch with repository secrets. It is written here and run in
  Stage 11 ([#24](https://github.com/pedrobtz/zulake/issues/24)).

**Tests.**

- Requests: what the request fake recorded (method, path, query,
  `Range`, `Authorization`, `x-ms-version`), including `List Blobs`
  pagination across a marker, in `test-azure.R`.
- Emulator: the snapshot and full read of every fixture uploaded to
  Azurite equal `deltalake`'s on the same container (acceptance 4a), in
  `test-azure-emulator.R`.
- `401`: `credentials()` called exactly twice, then a classed error, with
  `zu_mock_transport`, in `test-azure.R`.
- Token absence: the token string appears in no print, error message,
  condition field, serialized snapshot or cassette, in `test-azure.R`.
- URI forms: all three resolve to the same requests; `s3://`, `gs://` and
  others are refused, in `test-azure.R`.
- Live: the snapshot and full read of a table on ADLS Gen2 equal
  `deltalake`'s on the same table (acceptance 4b), in `test-azure-live.R`;
  written and skipping cleanly here, run in Stage 11.

**Exit criteria.**

- `R CMD check` passes on the quick r-actions profile.
- `azure-emulator.yaml` green on the pull request.
- `test-azure-live.R` skips cleanly without `ZULAKE_AZURE_URI`.
- Changed 2026-11-26: the green live run moved to Stage 11, because no
  storage account or token is available yet (D13).
- Every `**Tests.**` line exists, compares against the named oracle, and
  was seen to fail.
- `.agents/assurance.md` has the Azure Blob REST boundary row.

**Deviations (2026-11-26).**

- Azurite refuses a bad token with `403`, not Azure's `401`, so the `401`
  retry is tested with the request fake only; the emulator suite tests the
  refusal (design D13).
- `deltalake` 1.7.0 on Azurite opens no version of `simple_table` but the
  latest (it lists `_delta_log/` recursively and finds
  `_delta_log/.tmp/`), so those five cases are compared with zulake's local
  answers only, and asserted to be that refusal (design section 8).
- A second internal option, `zulake.azure_client`, carries the fake, the
  cassettes and Azurite's CA (design section 8).

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
  *Settled (2026-11-26):* a new fixture `zl-orders`, zulake's own, built
  for it ([§8](design.md#8-testing-and-validation)).
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

## Stage 2b — Checkpoints

**Issue.** [#26](https://github.com/pedrobtz/zulake/issues/26), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zulake/issues/1).

**CI.** `quick`.

**Goal.** Replay starts from the latest checkpoint, as the protocol
prescribes, so tables whose early commits were cleaned up open.

Scheduled when `qio` reads nested columns
([pedrobtz/qio#73](https://github.com/pedrobtz/qio/issues/73),
[D14](design.md#10-decisions)), and before Stage 8. It keeps the number 2b
because it is the half of Stage 2 that was split off on 2026-11-26.

**Work.**

- Classic, multi-part and V2 checkpoints, and V2 sidecars, read through
  `qio` ([§4.2](design.md#42-log-replay)); replay from the checkpoint the
  `_last_checkpoint` file or the listing names.
- `zulake_error_checkpoint_unreadable` remains only for a log that has
  neither commit 0 nor a readable checkpoint.
- `Imports: qio` at the version that reads nested columns, with
  `Remotes:` until it is on CRAN.

**Tests.**

- Checkpoint kinds (classic, multi-part, V2 with sidecars): replay from the
  checkpoint equals replay from commit 0 on the same table, and both equal
  `deltalake`, in `test-replay.R`.
- A fixture copy with every commit before the checkpoint removed: the same
  snapshot as the full log, in `test-replay.R`.
- Checkpoint hostile fixtures (a missing checkpoint part, a
  `_last_checkpoint` past the log): a classed `zulake_error`, and no
  snapshot object is returned, in `test-hostile.R`.

**Exit criteria.**

- `R CMD check` passes on the quick r-actions profile.
- Every `**Tests.**` line exists, compares against the named oracle, and
  was seen to fail.
- `.agents/assurance.md` has the checkpoints Boundaries row.

**Design.** [§4.2](design.md#42-log-replay), [D14](design.md#10-decisions).

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

**Deviations (2026-11-26).** The kinds `lifecycle` (the credential
handle) and `emits` (the Blob REST requests) were added, with an Objects
table and seven Limits rows. The coverage gap list was closed in the
stage's pull request rather than filed: one new test per branch no test
entered, except branches no input can reach, which the pull request
lists. It found one wrong result, fixed there (a checkpoint `LIST` of
longs read as `integer64`), and one deliberate difference from R now
written down (`is.na()` of a `binary` column, design §6). `Depends: R (>=
3.5.0)` closes [#37](https://github.com/pedrobtz/zulake/issues/37), and
[#39](https://github.com/pedrobtz/zulake/issues/39) moved to "After
0.1.0".

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

- `zuhttp`, `zuroar` and the nested-reading `qio` on CRAN; `Remotes:` removed
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

*Deviation (2026-11-27, maintainer):* the critical review runs before
Stage 10. Stage 10 waits on `zuhttp` and `zuroar` reaching CRAN, and on
`qio` 0.2.0 with nested reading. The review and its fixes go ahead
meanwhile. `pkg-cran-review` runs again after Stage 10 removes `Remotes:`,
so that its table describes the commit that is submitted.

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
- The live Azure suite green once against ADLS Gen2 (acceptance 4b,
  [#24](https://github.com/pedrobtz/zulake/issues/24)), or the
  maintainer's recorded decision to drop it.

  *Deviation (2026-11-27, maintainer):* the live run is deferred and the
  maintainer runs it; [#24](https://github.com/pedrobtz/zulake/issues/24)
  leaves the Review issue and does not block 0.1.0.
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
- The reader features `typeWidening`, `variantType` and
  `variantShredding` (and their `-preview` names), refused by name until
  then: each needs values converted or decoded on read
  ([D7 amendment](design.md#10-decisions), 2026-11-26).
- [§12](design.md#12-open-questions) Q4: caching downloads across sessions;
  0.1.0 caches per `lake_open()`.
- [§12](design.md#12-open-questions) Q6: probing commit names instead of
  listing; listing is correct, only possibly slow.
- The live Azure suite against ADLS Gen2
  ([#24](https://github.com/pedrobtz/zulake/issues/24), acceptance 4b),
  run by the maintainer.
- Turning checkpoint rows into actions vectorised
  ([#39](https://github.com/pedrobtz/zulake/issues/39)): 2.4 s of a 3.2 s
  open for a 20,000-file checkpoint, against 23 to 38 ms for the fixtures;
  correct as it is, only slow on large tables.

## Blocking open questions

- [D5](design.md#10-decisions), [D9](design.md#10-decisions) and
  [D14](design.md#10-decisions) block Stage 10: `zuhttp`, `zuroar` and a
  `qio` that reads nested columns on CRAN.
- [D14](design.md#10-decisions) blocks Stage 2b:
  [pedrobtz/qio#73](https://github.com/pedrobtz/qio/issues/73).

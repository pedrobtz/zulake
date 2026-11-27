# Hostile-log fixtures: good fixture tables, each broken in one way.
#
#   Rscript tools/fixtures/hostile.R
#
# Writes tests/testthat/fixtures/hostile/<name>/ from the tables under
# tests/testthat/fixtures/tables/, replacing what is there. Base R only, and
# deterministic: the same tables give the same bytes, so
# .github/workflows/oracle.yaml reruns it and fails on any diff. Each fixture
# must make zulake raise a classed `zulake_error` and return nothing (design
# section 8, roadmap Stages 2 and 5). The changes are listed in
# tests/testthat/fixtures/PROVENANCE.md; change both together.

if (!file.exists("DESCRIPTION") || !dir.exists("tools/fixtures")) {
  stop("run from the package root: Rscript tools/fixtures/hostile.R", call. = FALSE)
}

tables <- file.path("tests", "testthat", "fixtures", "tables")
hostile <- file.path("tests", "testthat", "fixtures", "hostile")

copy_table <- function(from, name) {
  src <- file.path(tables, from)
  stopifnot(dir.exists(src))
  dest <- file.path(hostile, name)
  unlink(dest, recursive = TRUE)
  files <- list.files(src, recursive = TRUE, all.files = TRUE, no.. = TRUE)
  for (f in files) {
    dir.create(dirname(file.path(dest, f)), recursive = TRUE, showWarnings = FALSE)
    stopifnot(file.copy(file.path(src, f), file.path(dest, f)))
  }
  dest
}

commit_path <- function(dir, version) {
  file.path(dir, "_delta_log", sprintf("%020d.json", version))
}

read_bytes <- function(path) readBin(path, "raw", file.size(path))

write_bytes <- function(path, bytes) {
  con <- file(path, "wb")
  on.exit(close(con))
  writeBin(bytes, con)
}

read_lines <- function(path) readLines(path, warn = FALSE, encoding = "UTF-8")

write_lines <- function(path, lines) {
  con <- file(path, "wb")
  on.exit(close(con))
  writeBin(charToRaw(paste0(paste(lines, collapse = "\n"), "\n")), con)
}

# The one deletion-vector file of a table copied from table-with-dv-small.
dv_file <- function(dir) {
  f <- list.files(dir, pattern = "^deletion_vector_.*[.]bin$", full.names = TRUE)
  stopifnot(length(f) == 1L)
  f
}

unlink(hostile, recursive = TRUE)
dir.create(hostile, recursive = TRUE)

# A commit cut off halfway through a line, as a writer that died would leave it.
d <- copy_table("zl-basic", "truncated-commit")
f <- commit_path(d, 4L)
b <- read_bytes(f)
write_bytes(f, b[seq_len(length(b) %/% 2L)])

# A commit whose second line is not JSON.
d <- copy_table("zl-basic", "corrupt-commit")
f <- commit_path(d, 2L)
lines <- read_lines(f)
lines[2L] <- "{\"add\": {\"path\": \"part-0.parquet\", \"size\": 12,, }"
write_lines(f, lines)

# A three-part checkpoint with its second part gone; _last_checkpoint still
# says parts = 3.
d <- copy_table("zl-multipart-checkpoint", "missing-checkpoint-part")
part <- list.files(
  file.path(d, "_delta_log"),
  pattern = "[.]checkpoint[.]0000000002[.]0000000003[.]parquet$",
  full.names = TRUE
)
stopifnot(length(part) == 1L)
unlink(part)

# _last_checkpoint pointing at version 99, past the last commit (12).
d <- copy_table("zl-checkpoint", "last-checkpoint-past-log")
write_lines(
  file.path(d, "_delta_log", "_last_checkpoint"),
  "{\"version\":99,\"size\":20}"
)

# A deletion vector whose CRC-32 (the four bytes after the bitmap) is wrong.
d <- copy_table("table-with-dv-small", "dv-bad-checksum")
f <- dv_file(d)
b <- read_bytes(f)
n <- length(b)
b[n] <- xor(b[n], as.raw(0xff))
write_bytes(f, b)

# A deletion vector whose magic number (bytes 6 to 9 of the file) differs.
d <- copy_table("table-with-dv-small", "dv-bad-magic")
f <- dv_file(d)
b <- read_bytes(f)
b[6:9] <- as.raw(c(0x00, 0x00, 0x00, 0x00))
write_bytes(f, b)

# A deletion vector descriptor whose sizeInBytes runs past the end of its file.
d <- copy_table("table-with-dv-small", "dv-size-past-file")
f <- commit_path(d, 1L)
lines <- read_lines(f)
stopifnot(sum(grepl("\"sizeInBytes\":36", lines, fixed = TRUE)) == 1L)
lines <- sub("\"sizeInBytes\":36", "\"sizeInBytes\":4096", lines, fixed = TRUE)
write_lines(f, lines)

# An integer partition column whose value in one add action is not a number.
d <- copy_table("zl-partitioned", "partition-value-wrong-type")
f <- commit_path(d, 1L)
lines <- read_lines(f)
stopifnot(sum(grepl("\"p_int\":\"1\"", lines, fixed = TRUE)) == 1L)
lines <- sub("\"p_int\":\"1\"", "\"p_int\":\"one\"", lines, fixed = TRUE)
write_lines(f, lines)

# Decimal partition values the comparator cannot read, or that the column's
# type cannot hold: zl-decimal-partitions' file of id 0 has pdec 12.30 in a
# decimal(10,2) and pd4 12.34 in a decimal(4,2). deltalake 1.7.0 refuses
# each of these tables (#112).
decimal_partition <- function(name, from, to) {
  d <- copy_table("zl-decimal-partitions", name)
  f <- commit_path(d, 0L)
  lines <- read_lines(f)
  stopifnot(sum(grepl(from, lines, fixed = TRUE)) == 1L)
  lines <- sub(from, to, lines, fixed = TRUE)
  write_lines(f, lines)
}
pdec <- "\"pdec\":\"12.30\""
pd4 <- "\"pd4\":\"12.34\""
decimal_partition("decimal-partition-no-integer-digit", pdec, "\"pdec\":\".5\"")
decimal_partition("decimal-partition-no-fraction-digit", pdec, "\"pdec\":\"5.\"")
decimal_partition("decimal-partition-negative-no-integer-digit", pdec, "\"pdec\":\"-.5\"")
decimal_partition("decimal-partition-exponent", pdec, "\"pdec\":\"1e2\"")
decimal_partition("decimal-partition-past-scale", pdec, "\"pdec\":\"12.345\"")
decimal_partition("decimal-partition-past-precision", pdec, "\"pdec\":\"123456789.00\"")
decimal_partition("decimal-partition-past-precision-small", pd4, "\"pd4\":\"123.45\"")

# A name-mode column mapping table whose field `letter` has no physical
# name in commit 0's schema; commit 2's schema has it again (#77).
d <- copy_table("column_mapping", "column-mapping-no-physical-name")
f <- commit_path(d, 0L)
lines <- read_lines(f)
drop <- ',\\"delta.columnMapping.physicalName\\":\\"col-4ef4d1f5-5d3c-4aad-b4db-405ac3f186e6\\"'
stopifnot(sum(grepl(drop, lines, fixed = TRUE)) == 1L)
lines <- sub(drop, "", lines, fixed = TRUE)
write_lines(f, lines)

# zl-basic's commit 2 adds part-...e10fff6f... (line 2) and removes
# part-...8d16a499... (line 3); part-...ede65999... is live from commit 1.
added <- "part-00000-e10fff6f-4360-42ee-8090-3f777493cca7-c000.snappy.parquet"
removed <- "part-00000-8d16a499-c579-4a11-8219-2a6315388180-c000.snappy.parquet"
live <- "part-00000-ede65999-d150-4938-a3e5-58b246210db5-c000.snappy.parquet"

# An add whose `path` key is there twice: zujson's lookup takes the first,
# deltalake the last (#102).
d <- copy_table("zl-basic", "duplicate-key-in-add")
f <- commit_path(d, 2L)
lines <- read_lines(f)
first <- sprintf("{\"add\":{\"path\":\"%s\",", added)
stopifnot(startsWith(lines[2L], first))
lines[2L] <- sub(first, sprintf("%s\"path\":\"%s\",", first, removed), lines[2L], fixed = TRUE)
write_lines(f, lines)

# A line holding two `remove` actions under one key: the second removes the
# file commit 1 added (#102).
d <- copy_table("zl-basic", "duplicate-action-key")
f <- commit_path(d, 2L)
lines <- read_lines(f)
stopifnot(startsWith(lines[3L], "{\"remove\":{") && endsWith(lines[3L], "}}"))
lines[3L] <- sprintf(
  "%s,\"remove\":{\"path\":\"%s\",\"dataChange\":true,\"deletionTimestamp\":1795690965419}}",
  substr(lines[3L], 1L, nchar(lines[3L]) - 1L),
  live
)
write_lines(f, lines)

# A commit that adds a file and then removes it, and one that removes it
# and then adds it: the protocol forbids both (#103).
remove_added <- sprintf(
  "{\"remove\":{\"path\":\"%s\",\"dataChange\":true,\"deletionTimestamp\":1795690965419}}",
  added
)
d <- copy_table("zl-basic", "add-then-remove-same-file")
f <- commit_path(d, 2L)
lines <- read_lines(f)
stopifnot(length(lines) == 3L, startsWith(lines[2L], first))
write_lines(f, c(lines, remove_added))
d <- copy_table("zl-basic", "remove-then-add-same-file")
f <- commit_path(d, 2L)
write_lines(f, c(lines[1L], remove_added, lines[2:3]))

# A commit with two adds of one path, the second with other statistics: the
# protocol allows one add per path in a commit (#106).
d <- copy_table("zl-basic", "two-adds-same-file")
f <- commit_path(d, 2L)
lines <- read_lines(f)
stopifnot(length(lines) == 3L, startsWith(lines[2L], first))
min_one <- "\\\"minValues\\\":{\\\"id\\\":1,"
stopifnot(grepl(min_one, lines[2L], fixed = TRUE))
again <- sub(min_one, "\\\"minValues\\\":{\\\"id\\\":0,", lines[2L], fixed = TRUE)
write_lines(f, c(lines[1:2], again, lines[3L]))

# A commit with two adds of one path under two deletion vectors: its own
# (on disk) and table-with-dv-small-inline's (inline). Replay keeps both as
# two logical files, so the file would be read twice (#106).
d <- copy_table("table-with-dv-small", "two-adds-same-path-new-dv")
f <- commit_path(d, 1L)
lines <- read_lines(f)
inline <- read_lines(commit_path(file.path(tables, "table-with-dv-small-inline"), 1L))
stopifnot(
  length(lines) == 3L,
  startsWith(lines[3L], "{\"add\":{"),
  grepl("\"storageType\":\"u\"", lines[3L], fixed = TRUE),
  startsWith(inline[3L], "{\"add\":{"),
  grepl("\"storageType\":\"i\"", inline[3L], fixed = TRUE)
)
write_lines(f, c(lines, inline[3L]))

# A commit with two removes of one path, at two times (#106).
d <- copy_table("zl-basic", "two-removes-same-file")
f <- commit_path(d, 3L)
lines <- read_lines(f)
j <- which(startsWith(lines, sprintf("{\"remove\":{\"path\":\"%s\",", added)))
stopifnot(length(j) == 1L, grepl("\"deletionTimestamp\":1795690965425", lines[j], fixed = TRUE))
again <- sub("\"deletionTimestamp\":1795690965425", "\"deletionTimestamp\":1795690965426", lines[j], fixed = TRUE)
write_lines(f, append(lines, again, after = j))

# zl-basic's commit 4 adds part-...08a25d6d... (line 2), live at the last
# version; its statistics have id 12 for both bounds.
stats_line <- function(lines) {
  j <- which(startsWith(lines, "{\"add\":{\"path\":\"part-00000-08a25d6d-"))
  stopifnot(length(j) == 1L)
  j
}

# Statistics with `maxValues` twice, the first saying id 11: zujson's lookup
# would take it and prune the file for `id == 12` (#107).
d <- copy_table("zl-basic", "stats-repeated-key")
f <- commit_path(d, 4L)
lines <- read_lines(f)
j <- stats_line(lines)
max_12 <- "\\\"maxValues\\\":{\\\"id\\\":12,"
stopifnot(grepl(max_12, lines[j], fixed = TRUE))
lines[j] <- sub(max_12, paste0("\\\"maxValues\\\":{\\\"id\\\":11},", max_12), lines[j], fixed = TRUE)
write_lines(f, lines)

# Statistics whose `minValues` holds `id` twice, 13 first (#107).
d <- copy_table("zl-basic", "stats-repeated-column")
f <- commit_path(d, 4L)
lines <- read_lines(f)
j <- stats_line(lines)
min_12 <- "\\\"minValues\\\":{\\\"id\\\":12,"
stopifnot(grepl(min_12, lines[j], fixed = TRUE))
lines[j] <- sub(min_12, "\\\"minValues\\\":{\\\"id\\\":13,\\\"id\\\":12,", lines[j], fixed = TRUE)
write_lines(f, lines)

# A schema whose field `id` has `type` twice, "string" first (#107).
d <- copy_table("zl-basic", "schema-repeated-key")
f <- commit_path(d, 0L)
lines <- read_lines(f)
id_long <- "{\\\"name\\\":\\\"id\\\",\\\"type\\\":\\\"long\\\","
stopifnot(sum(grepl(id_long, lines, fixed = TRUE)) == 1L)
lines <- sub(
  id_long,
  "{\\\"name\\\":\\\"id\\\",\\\"type\\\":\\\"string\\\",\\\"type\\\":\\\"long\\\",",
  lines,
  fixed = TRUE
)
write_lines(f, lines)

# A line holding two actions: zl-basic's commit 2 with its add (line 2) and
# its remove (line 3) on one line. The protocol stores every action on a
# line of its own (#121).
d <- copy_table("zl-basic", "two-actions-one-line")
f <- commit_path(d, 2L)
lines <- read_lines(f)
stopifnot(
  length(lines) == 3L,
  startsWith(lines[2L], first),
  endsWith(lines[2L], "}}"),
  startsWith(lines[3L], "{\"remove\":{")
)
lines[2L] <- paste0(substr(lines[2L], 1L, nchar(lines[2L]) - 1L), ",", substring(lines[3L], 2L))
write_lines(f, lines[1:2])

# Schemas zulake cannot read as written, each made from zl-basic's commit 0
# (fields id long, label string, x double) by one edit of its schemaString
# (#120).
schema_edit <- function(name, from, to, table = "zl-basic") {
  d <- copy_table(table, name)
  f <- commit_path(d, 0L)
  lines <- read_lines(f)
  stopifnot(sum(grepl(from, lines, fixed = TRUE)) == 1L)
  lines <- sub(from, to, lines, fixed = TRUE)
  write_lines(f, lines)
}
label <- "{\\\"name\\\":\\\"label\\\",\\\"type\\\":\\\"string\\\","
x_name <- "{\\\"name\\\":\\\"x\\\","
schema_edit("schema-unknown-type", label, "{\\\"name\\\":\\\"label\\\",\\\"type\\\":\\\"varchar(10)\\\",")
schema_edit("schema-upper-case-type", label, "{\\\"name\\\":\\\"label\\\",\\\"type\\\":\\\"STRING\\\",")
schema_edit("schema-field-without-type", label, "{\\\"name\\\":\\\"label\\\",")
schema_edit("schema-variant-without-feature", label, "{\\\"name\\\":\\\"label\\\",\\\"type\\\":\\\"variant\\\",")
schema_edit("schema-timestamp-ntz-without-feature", label, "{\\\"name\\\":\\\"label\\\",\\\"type\\\":\\\"timestamp_ntz\\\",")
schema_edit("schema-duplicate-name", x_name, "{\\\"name\\\":\\\"label\\\",")
schema_edit("schema-field-without-name", x_name, "{")
schema_edit("schema-empty-name", x_name, "{\\\"name\\\":\\\"\\\",")

# Names that differ only in case, which PROTOCOL.md does not allow: field
# `x` renamed `LABEL` beside `label`, and `x` typed as a struct with fields
# `a` and `A` (#134).
schema_edit("schema-duplicate-name-case", x_name, "{\\\"name\\\":\\\"LABEL\\\",")
x_double <- "{\\\"name\\\":\\\"x\\\",\\\"type\\\":\\\"double\\\","
schema_edit(
  "schema-duplicate-name-case-nested",
  x_double,
  paste0(
    "{\\\"name\\\":\\\"x\\\",\\\"type\\\":{\\\"type\\\":\\\"struct\\\",\\\"fields\\\":[",
    "{\\\"name\\\":\\\"a\\\",\\\"type\\\":\\\"long\\\",\\\"nullable\\\":true,\\\"metadata\\\":{}},",
    "{\\\"name\\\":\\\"A\\\",\\\"type\\\":\\\"long\\\",\\\"nullable\\\":true,\\\"metadata\\\":{}}]},"
  )
)

# A schema whose type for a column is not the one its data files hold
# (#119): zl-types' `s` (strings, in its one data file, so that deltalake's
# refusal names one value whatever order it reads files in) typed `long`,
# and zl-basic's `id` (INT64 in every file) typed `integer`.
schema_edit(
  "data-type-string-for-long",
  "{\\\"name\\\":\\\"s\\\",\\\"type\\\":\\\"string\\\",",
  "{\\\"name\\\":\\\"s\\\",\\\"type\\\":\\\"long\\\",",
  table = "zl-types"
)
schema_edit("data-type-long-for-integer", id_long, "{\\\"name\\\":\\\"id\\\",\\\"type\\\":\\\"integer\\\",")

# A name-mode table whose fields `letter` and `int` have one physical name
# in commit 0's schema; commit 2's schema has `int`'s own again (#120).
d <- copy_table("column_mapping", "column-mapping-duplicate-physical-name")
f <- commit_path(d, 0L)
lines <- read_lines(f)
int_physical <- '\\"delta.columnMapping.physicalName\\":\\"col-12668372-ff50-41ae-9571-41f0cb9ad88f\\"'
stopifnot(sum(grepl(int_physical, lines, fixed = TRUE)) == 1L)
lines <- sub(
  int_physical,
  '\\"delta.columnMapping.physicalName\\":\\"col-4ef4d1f5-5d3c-4aad-b4db-405ac3f186e6\\"',
  lines,
  fixed = TRUE
)
write_lines(f, lines)

# checkpoint-map-repeated-key needs a Parquet writer: hostile_parquet.py
# writes it after this script.

cat("wrote", length(list.dirs(hostile, recursive = FALSE)), "hostile fixtures\n")

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

cat("wrote", length(list.dirs(hostile, recursive = FALSE)), "hostile fixtures\n")

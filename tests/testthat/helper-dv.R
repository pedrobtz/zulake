# Helpers for the deletion-vector tests (test-dv.R, test-hostile.R). Here,
# not in a test file, because the suite shuffles every top-level expression
# of a test file. They build deletion vectors without zulake's own code: a
# Z85 encoder written from RFC 32, and CRC-32 from zlib, through the gzip
# trailer R's gzfile() writes.

# Z85 text for `bytes` (a raw vector whose length is a multiple of 4).
test_z85_encode <- function(bytes) {
  alphabet <- strsplit("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#", "")[[1L]]
  stopifnot(length(bytes) %% 4L == 0L)
  out <- character()
  for (g in seq_len(length(bytes) %/% 4L)) {
    b <- as.numeric(bytes[(g - 1L) * 4L + 1:4])
    value <- ((b[1L] * 256 + b[2L]) * 256 + b[3L]) * 256 + b[4L]
    chars <- character(5L)
    for (k in 5:1) {
      chars[k] <- alphabet[value %% 85 + 1]
      value <- value %/% 85
    }
    out <- c(out, chars)
  }
  paste(out, collapse = "")
}

# The CRC-32 of `bytes` as zlib computes it, read from the trailer of a gzip
# file (RFC 1952: CRC-32 then the length, both little-endian).
test_crc32 <- function(bytes) {
  f <- tempfile(fileext = ".gz")
  on.exit(unlink(f))
  con <- gzfile(f, "wb", compression = 1)
  writeBin(bytes, con)
  close(con)
  z <- readBin(f, "raw", file.size(f))
  trailer <- z[length(z) - 7:4]
  sum(as.numeric(trailer) * 256^(0:3))
}

be_bytes <- function(x) {
  as.raw(c(x %/% 2^24, x %/% 2^16 %% 256, x %/% 2^8 %% 256, x %% 256))
}

# The bytes of a deletion vector deleting `rows` (0-based, as decimal text
# or doubles): the magic number, then the portable 64-bit Roaring bitmap.
dv_bytes <- function(rows, magic = 1681511377) {
  bitmap <- zuroar::roar_serialize(zuroar::roar64(rows))
  c(as.raw(c(magic %% 256, magic %/% 2^8 %% 256, magic %/% 2^16 %% 256, magic %/% 2^24)), bitmap)
}

# A deletion vector file holding the vectors `vectors` (a list of raw
# vectors), as the protocol lays it out; returns the offset of each.
write_dv_file <- function(path, vectors, version = 1L, crc = test_crc32) {
  bytes <- as.raw(version)
  offsets <- numeric()
  for (v in vectors) {
    offsets <- c(offsets, length(bytes))
    bytes <- c(bytes, be_bytes(length(v)), v, be_bytes(crc(v)))
  }
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeBin(bytes, path)
  offsets
}

# 16 random bytes of a UUID, and its 20 characters of Z85.
random_uuid <- function() {
  as.raw(sample(0:255, 16L, replace = TRUE))
}

# A table of one data file of `n` rows (`id` 0 to n - 1, as doubles), whose
# deletion vector (`dv`, a descriptor list) is in the log; `extra` files are
# added without one. Returns the table's path.
dv_table <- function(dv, n = 10L, env = parent.frame(), stats = TRUE) {
  path <- file.path(withr::local_tempdir(.local_envir = env), "table")
  dir.create(path)
  qio::write_parquet(data.frame(id = as.numeric(seq_len(n) - 1L)), file.path(path, "part-0.parquet"))
  add <- list(
    path = "part-0.parquet", partitionValues = structure(list(), names = character()),
    size = file.size(file.path(path, "part-0.parquet")), modificationTime = 0, dataChange = TRUE
  )
  if (stats) add$stats <- sprintf('{"numRecords":%d}', n)
  if (!is.null(dv)) add$deletionVector <- dv
  write_commit(path, 0, c(
    protocol_line(3L, 7L, "deletionVectors", "deletionVectors"),
    metadata_line(c(id = "double")),
    json_line(list(add = add))
  ))
  path
}

# An inline descriptor for the vector `bytes`, padded to 4 bytes as Delta
# pads it.
inline_dv <- function(bytes, cardinality) {
  size <- length(bytes)
  pad <- (4L - size %% 4L) %% 4L
  list(storageType = "i", pathOrInlineDv = test_z85_encode(c(bytes, raw(pad))),
       sizeInBytes = size, cardinality = cardinality)
}

# Every live file's rows as qio reads them, deletion vectors not applied:
# list of data frames, by file (for tables without partitions or column
# mapping).
read_each_file_raw <- function(tbl) {
  lapply(seq_len(nrow(tbl$files)), function(i) qio::read_parquet(fetch_file(tbl, i)))
}

#' Deletion vectors
#'
#' `lake_deletion_vectors()` lists the deletion vectors of a snapshot's live
#' files: one row per file that has one, with the descriptor the log holds
#' and, with `rows = TRUE`, the rows it deletes. A deletion vector marks rows
#' of a data file as deleted without rewriting the file; [lake_read()] and
#' [lake_walk()] never return those rows, and [lake_count()] subtracts their
#' number.
#'
#' A descriptor's `storage_type` says where the vector is: `"i"` inline in
#' the log (`path_or_inline_dv` is the vector itself, Z85-encoded), `"u"` in
#' a file of the table whose name is derived from a UUID
#' (`path_or_inline_dv` is an optional prefix and the Z85-encoded UUID), or
#' `"p"` in a file at an absolute path. A vector in a file is read by range
#' at `offset`, and its CRC-32 checksum is verified. The rows are those of
#' the Roaring bitmap the vector holds, decoded by the zuroar package, which
#' zulake suggests rather than imports: without it, `rows = TRUE`, and any
#' read of a table with deletion vectors, is an error of class
#' `zulake_error_missing_package` naming `zuroar`.
#'
#' A vector whose checksum, magic number, size or row count does not agree
#' with its descriptor is an error of class `zulake_error_corrupt_log`, and
#' no rows are returned.
#'
#' @inheritParams lake_files
#' @param files `NULL`, the default, for every live file, or a character
#'   vector of files, each a `path` or `uri` as [lake_files()] gives them.
#' @param rows Whether to read each vector and return the rows it deletes.
#'   With `FALSE`, only the descriptors from the log are returned: nothing
#'   is read, and zuroar is not needed.
#' @returns A data frame with one row per live file that has a deletion
#'   vector, in the order of [lake_files()]: `uri` (the data file),
#'   `storage_type`, `path_or_inline_dv`, `offset` (`NA` for an inline
#'   vector), `size_in_bytes` and `cardinality` (the number of rows deleted),
#'   all from the log, and with `rows = TRUE`, `rows`, a list column of the
#'   deleted rows' positions in the data file: sorted doubles, counted from
#'   0 as the protocol counts them. A position of 2^53 or more, which a
#'   double cannot hold exactly, is an error of class `zulake_error_int64`.
#' @seealso [lake_files()], whose `deletion_vector` column holds the same
#'   descriptors.
#' @export
#' @examples
#' # The example table the package ships has no deletion vector:
#' orders <- lake_open(system.file("extdata", "orders", package = "zulake"))
#' lake_deletion_vectors(orders, rows = FALSE)
#'
#' # A table of one file of ten rows, whose rows 0 and 9 are deleted by a
#' # deletion vector written inline in the log.
#' path <- tempfile("table")
#' dir.create(file.path(path, "_delta_log"), recursive = TRUE)
#' qio::write_parquet(data.frame(value = 0:9), file.path(path, "part-0.parquet"))
#' writeLines(c(
#'   paste0(
#'     '{"protocol":{"minReaderVersion":3,"minWriterVersion":7,',
#'     '"readerFeatures":["deletionVectors"],"writerFeatures":["deletionVectors"]}}'
#'   ),
#'   paste0(
#'     '{"metaData":{"id":"example","format":{"provider":"parquet","options":{}},',
#'     '"schemaString":"{\\"type\\":\\"struct\\",\\"fields\\":[',
#'     '{\\"name\\":\\"value\\",\\"type\\":\\"integer\\",\\"nullable\\":true,\\"metadata\\":{}}]}",',
#'     '"partitionColumns":[],"configuration":{}}}'
#'   ),
#'   sprintf(
#'     paste0(
#'       '{"add":{"path":"part-0.parquet","partitionValues":{},"size":%.0f,',
#'       '"modificationTime":0,"dataChange":true,"stats":"{\\"numRecords\\":10}",',
#'       '"deletionVector":{"storageType":"i",',
#'       '"pathOrInlineDv":"^Bg9^0rr910000000000iXQKl0rr91000315c8Xg000r9",',
#'       '"sizeInBytes":36,"cardinality":2}}}'
#'     ),
#'     file.size(file.path(path, "part-0.parquet"))
#'   )
#' ), file.path(path, "_delta_log", "00000000000000000000.json"))
#'
#' tbl <- lake_open(path)
#' lake_deletion_vectors(tbl, rows = FALSE)
#' lake_count(tbl)
#' if (requireNamespace("zuroar", quietly = TRUE)) {
#'   print(lake_deletion_vectors(tbl)$rows)
#'   print(lake_read(tbl))
#' }
#'
#' unlink(path, recursive = TRUE)
lake_deletion_vectors <- function(tbl, files = NULL, rows = TRUE) {
  check_table(tbl)
  if (!isTRUE(rows) && !isFALSE(rows)) {
    zulake_abort("argument", "`rows` must be TRUE or FALSE.")
  }
  paths <- tbl$files$path
  uris <- file_uri(tbl, paths)
  pick <- seq_along(paths)
  if (!is.null(files)) {
    if (!is.character(files) || anyNA(files)) {
      zulake_abort("argument", "`files` must be NULL or a character vector of file paths or URIs.")
    }
    at <- ifelse(is.na(match(files, paths)), match(files, uris), match(files, paths))
    if (anyNA(at)) {
      zulake_abort(
        "argument",
        sprintf("`files` names %s, which is not a live file of this snapshot.", format_string(files[is.na(at)][1L]))
      )
    }
    pick <- sort(unique(at))
  }
  actions <- tbl$files$action
  pick <- pick[!vapply(actions[pick], function(a) is.null(a[["deletionVector"]]), NA)]
  dvs <- lapply(actions[pick], function(a) a[["deletionVector"]])
  num <- function(name, what) {
    int64_values(lapply(dvs, function(d) d[[name]]), "double", sprintf("a deletion vector's `%s`", what))
  }
  out <- list(
    uri = uris[pick],
    storage_type = vapply(dvs, function(d) d[["storageType"]], "", USE.NAMES = FALSE),
    path_or_inline_dv = vapply(dvs, function(d) d[["pathOrInlineDv"]], "", USE.NAMES = FALSE),
    offset = num("offset", "offset"),
    size_in_bytes = num("sizeInBytes", "sizeInBytes"),
    cardinality = num("cardinality", "cardinality")
  )
  if (rows) {
    out$rows <- dv_rows_of(tbl, pick)
  }
  new_data_frame_n(out, length(pick))
}

# ---- the rows of deletion vectors ----------------------------------------

# The deleted row positions (sorted, 0-based doubles) of live files `idx`,
# each of which has a deletion vector. Every vector is read and checked
# before any is returned, and zuroar is required only when there is one.
dv_rows_of <- function(tbl, idx) {
  if (!length(idx)) {
    return(list())
  }
  need_zuroar()
  versions <- new.env(parent = emptyenv())
  lapply(idx, function(i) dv_rows(tbl, i, versions))
}

zuroar_available <- function() {
  requireNamespace("zuroar", quietly = TRUE)
}

need_zuroar <- function() {
  if (!zuroar_available()) {
    zulake_abort(
      "missing_package",
      paste(
        "This table has deletion vectors, and reading them needs the zuroar package,",
        "which is not installed. Install it with pak::pak(\"pedrobtz/zuroar\");",
        "lake_deletion_vectors(rows = FALSE) and lake_count() work without it."
      ),
      package = "zuroar"
    )
  }
  invisible()
}

dv_magic <- 1681511377

# The rows the deletion vector of live file `i` deletes. `versions` caches,
# per deletion-vector file, that its format version byte was checked.
dv_rows <- function(tbl, i, versions) {
  a <- tbl$files$action[[i]]
  file <- a[["path"]]
  dv <- a[["deletionVector"]]
  bad <- function(problem) {
    zulake_abort(
      "corrupt_log",
      sprintf("The deletion vector of file %s %s.", format_string(file), problem),
      file = file
    )
  }
  what <- function(name) sprintf("a deletion vector's `%s`", name)
  size <- int64_values(list(dv[["sizeInBytes"]]), "double", what("sizeInBytes"))
  card <- int64_values(list(dv[["cardinality"]]), "double", what("cardinality"))
  if (is.na(size) || size < 4) {
    bad("has no valid `sizeInBytes`")
  }
  if (is.na(card) || card < 0) {
    bad("has no valid `cardinality`")
  }
  if (dv[["storageType"]] == "i") {
    bytes <- tryCatch(z85_decode(dv[["pathOrInlineDv"]]), zulake_error_z85 = function(e) {
      bad(sprintf("is not valid Z85 (%s)", conditionMessage(e)))
    })
    if (length(bytes) < size) {
      bad(sprintf("holds %s bytes inline, fewer than its `sizeInBytes` of %s", format_number(length(bytes)), format_number(size)))
    }
    data <- bytes[seq_len(size)]
  } else {
    offset <- if (is.null(dv[["offset"]])) 0 else int64_values(list(dv[["offset"]]), "double", what("offset"))
    where <- dv_file(tbl, dv, bad)
    if (is.na(where$size) || offset + 4 + size + 4 > where$size) {
      bad(sprintf(
        "runs past the end of %s: %s bytes from offset %s, in a file of %s bytes",
        format_string(where$name), format_number(4 + size + 4), format_number(offset),
        format_number(where$size)
      ))
    }
    if (is.null(versions[[where$name]])) {
      version <- where$range(0, 0)
      if (!identical(version, as.raw(1L))) {
        bad(sprintf("is in %s, whose format version is %s, not 1", format_string(where$name), format_number(as.integer(version[1L]))))
      }
      versions[[where$name]] <- TRUE
    }
    block <- where$range(offset, offset + 4 + size + 4 - 1)
    if (length(block) != 4 + size + 4) {
      bad(sprintf("could not be read whole from %s", format_string(where$name)))
    }
    stored <- be_uint32(block[1:4])
    if (stored != size) {
      bad(sprintf("has %s bytes in its file but %s in the log", format_number(stored), format_number(size)))
    }
    data <- block[4 + seq_len(size)]
    crc <- be_uint32(block[4 + size + 1:4])
    if (crc32(data) != crc) {
      bad(sprintf("fails its CRC-32 check (stored %s, computed %s)", hex32(crc), hex32(crc32(data))))
    }
  }
  magic <- sum(as.numeric(data[1:4]) * 256^(0:3))
  if (magic != dv_magic) {
    bad(sprintf("starts with magic number %s, not %s", format_number(magic), format_number(dv_magic)))
  }
  bitmap <- tryCatch(
    zuroar::roar64_unserialize(data[-(1:4)]),
    zuroar_error = function(e) bad(sprintf("is not a valid 64-bit Roaring bitmap (%s)", conditionMessage(e)))
  )
  n <- zuroar::roar64_length(bitmap)
  if (n != format_number(card)) {
    bad(sprintf("deletes %s rows, but its `cardinality` is %s", n, format_number(card)))
  }
  if (card == 0) {
    return(numeric())
  }
  top <- max(bitmap)
  if (nchar(top) > 16L || nchar(top) == 16L && sorts_after(top, "9007199254740991")) {
    zulake_abort(
      "int64",
      sprintf(
        "The deletion vector of file %s deletes row %s, which a double cannot hold exactly (the limit is 2^53 - 1).",
        format_string(file), top
      ),
      value = top
    )
  }
  as.double(bitmap)
}

# Where a deletion vector stored in a file is: `name` for messages, `size`
# (NA when there is no such file) and `range(from, to)`, 0-based inclusive.
dv_file <- function(tbl, dv, bad) {
  text <- dv[["pathOrInlineDv"]]
  if (dv[["storageType"]] == "u") {
    if (nchar(text) < 20L) {
      bad("has a `pathOrInlineDv` shorter than the 20 characters of a UUID")
    }
    n <- nchar(text)
    uuid <- tryCatch(z85_decode(substr(text, n - 19L, n)), zulake_error_z85 = function(e) {
      bad(sprintf("has a UUID that is not valid Z85 (%s)", conditionMessage(e)))
    })
    rel <- dv_relative_path(substr(text, 1L, n - 20L), uuid)
    if (bad_relative_path(rel)) {
      bad("has a prefix with an empty, \".\" or \"..\" path segment, which would leave the table's root")
    }
    storage <- tbl$storage
    info <- storage$head(rel)
    return(list(
      name = rel,
      size = if (is.null(info)) NA_real_ else info$size,
      range = function(from, to) storage$get_range(rel, from, to)
    ))
  }
  remote <- storage_for_absolute(tbl$storage, text)
  if (!is.null(remote)) {
    info <- remote$storage$head(remote$rel)
    return(list(
      name = text,
      size = if (is.null(info)) NA_real_ else info$size,
      range = function(from, to) remote$storage$get_range(remote$rel, from, to)
    ))
  }
  local <- absolute_local_path(text)
  size <- if (file.exists(local) && !dir.exists(local)) file.size(local) else NA_real_
  list(
    name = text,
    size = size,
    range = function(from, to) {
      con <- file(local, "rb")
      on.exit(close(con))
      seek(con, from)
      readBin(con, "raw", to - from + 1)
    }
  )
}

# `<prefix>/deletion_vector_<uuid>.bin`, or without the prefix when it is
# empty, from the 16 bytes of the UUID.
dv_relative_path <- function(prefix, uuid) {
  hex <- paste(sprintf("%02x", as.integer(uuid)), collapse = "")
  canonical <- paste(
    substr(hex, 1L, 8L), substr(hex, 9L, 12L), substr(hex, 13L, 16L), substr(hex, 17L, 20L),
    substr(hex, 21L, 32L),
    sep = "-"
  )
  name <- paste0("deletion_vector_", canonical, ".bin")
  if (nzchar(prefix)) paste0(prefix, "/", name) else name
}

hex32 <- function(x) {
  sprintf("%04x%04x", as.integer(x %/% 65536), as.integer(x %% 65536))
}

be_uint32 <- function(b) {
  sum(as.numeric(b) * 256^(3:0))
}

# ---- Z85 (ZeroMQ RFC 32) -------------------------------------------------

z85_alphabet <- utf8ToInt("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#")

# The bytes Z85 text encodes: each 5 characters a big-endian 32-bit value.
z85_decode <- function(text) {
  z85_error <- function(problem) {
    stop(structure(class = c("zulake_error_z85", "error", "condition"), list(message = problem, call = NULL)))
  }
  if (!is_string(text)) {
    z85_error("not a string")
  }
  chars <- utf8ToInt(enc2utf8(text))
  if (length(chars) %% 5L) {
    z85_error(sprintf("%s characters, not a multiple of 5", format_number(length(chars))))
  }
  digits <- match(chars, z85_alphabet) - 1
  if (anyNA(digits)) {
    z85_error(sprintf("character %s is not in the Z85 alphabet", format_string(intToUtf8(chars[is.na(digits)][1L]))))
  }
  if (!length(digits)) {
    return(raw())
  }
  m <- matrix(digits, nrow = 5L)
  value <- colSums(m * 85^(4:0))
  if (any(value > 2^32 - 1)) {
    z85_error("a group of 5 characters encodes more than 32 bits")
  }
  bytes <- rbind(value %/% 2^24, value %/% 2^16 %% 256, value %/% 2^8 %% 256, value %% 256)
  as.raw(as.vector(bytes))
}

# ---- CRC-32 (IEEE 802.3, as zlib and java.util.zip compute it) -----------

# The table, as 16-bit halves so that no value reaches R's NA_integer_.
crc32_table <- local({
  lo <- integer(256L)
  hi <- integer(256L)
  for (n in 0:255) {
    l <- n
    h <- 0L
    for (k in 1:8) {
      bit <- bitwAnd(l, 1L)
      l <- bitwOr(bitwShiftR(l, 1L), bitwShiftL(bitwAnd(h, 1L), 15L))
      h <- bitwShiftR(h, 1L)
      if (bit == 1L) {
        l <- bitwXor(l, 0x8320L)
        h <- bitwXor(h, 0xEDB8L)
      }
    }
    lo[n + 1L] <- l
    hi[n + 1L] <- h
  }
  list(lo = lo, hi = hi)
})

# The CRC-32 of raw vector `x`, as a double.
crc32 <- function(x) {
  lo <- 65535L
  hi <- 65535L
  tlo <- crc32_table$lo
  thi <- crc32_table$hi
  for (b in as.integer(x)) {
    j <- bitwAnd(bitwXor(lo, b), 255L) + 1L
    lo <- bitwXor(tlo[j], bitwOr(bitwShiftR(lo, 8L), bitwShiftL(bitwAnd(hi, 255L), 8L)))
    hi <- bitwXor(thi[j], bitwShiftR(hi, 8L))
  }
  (65535 - hi) * 65536 + (65535 - lo)
}

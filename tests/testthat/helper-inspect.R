# Helpers for the inspection tests (test-inspect.R, test-filter.R,
# test-types.R). Here, not in a test file, because the suite shuffles every
# top-level expression of a test file.

# Every (table, version) that both deltalake and zulake open: list of
# list(table, version), cached for the session.
inspect_cases <- function() {
  if (is.null(oracle_env$inspect_cases)) {
    cases <- list()
    for (table in fixture_names("tables")) {
      for (version in oracle_versions(table)) {
        if (!is.null(oracle_refusal(table, version))) next
        ok <- tryCatch({
          lake_open(fixture_table(table), version = version)
          TRUE
        }, zulake_error = function(e) FALSE)
        if (ok) cases[[length(cases) + 1L]] <- list(table = table, version = version)
      }
    }
    oracle_env$inspect_cases <- cases
  }
  oracle_env$inspect_cases
}

# Snapshot for a case, cached (snapshots never change).
case_snapshot <- function(case) {
  key <- paste("snapshot", case$table, case$version)
  if (is.null(oracle_env[[key]])) {
    oracle_env[[key]] <- lake_open(fixture_table(case$table), version = case$version)
  }
  oracle_env[[key]]
}

# `x` with every NULL and NA leaf removed, recursively; an object left empty
# is NULL. For comparing statistics, where deltalake writes null for a
# column the log has no statistic for.
strip_nulls <- function(x) {
  if (is.null(x)) {
    return(NULL)
  }
  if (is.list(x)) {
    out <- lapply(x, strip_nulls)
    out <- out[!vapply(out, is.null, NA)]
    if (!length(out)) {
      return(NULL)
    }
    return(out)
  }
  if (length(x) == 1L && is.na(x)) {
    return(NULL)
  }
  x
}

# deltalake's statistics keys are physical names under column mapping;
# zulake's are logical. The map from one to the other, from deltalake's own
# schema answer.
physical_to_logical <- function(table, version) {
  fields <- oracle_field(table, version, c("schema", "fields"))
  out <- character()
  for (f in fields) {
    phys <- f$metadata[["delta.columnMapping.physicalName"]]
    if (!is.null(phys)) out[[phys]] <- f$name
  }
  out
}

rename_keys <- function(x, map) {
  if (!is.list(x) || is.null(names(x)) || !length(map)) {
    return(x)
  }
  nm <- names(x)
  hit <- nm %in% names(map)
  nm[hit] <- unname(map[nm[hit]])
  names(x) <- nm
  x
}

# deltalake's live files at a version, keyed like zulake's
# (path and deletion vector).
oracle_file_keys <- function(table, version) {
  aa <- oracle_field(table, version, "add_actions")
  dv <- aa$columns$deletion_vector
  if (!is.list(dv)) dv <- vector("list", aa$num_rows)
  vapply(seq_len(aa$num_rows), function(i) {
    d <- dv[[i]]
    id <- if (is.null(d)) "" else paste0(d$storageType, d$pathOrInlineDv, if (!is.null(d$offset)) paste0("@", d$offset))
    paste0(aa$columns$path[[i]], "\x1f", id)
  }, "")
}

# The tombstones and domains the oracle's own parse of the commits leaves at
# `version`: replays deltalake-independent `actions` answers (Python's json).
oracle_replay_log <- function(table, version) {
  removes <- list()
  domains <- list()
  key <- function(x) {
    d <- x$deletionVector
    id <- if (is.null(d)) "" else paste0(d$storageType, d$pathOrInlineDv, if (!is.null(d$offset)) paste0("@", d$offset))
    paste0(x$path, "\x1f", id)
  }
  for (v in 0:version) {
    acts <- oracle_field(table, v, "actions")
    for (a in acts) if (!is.null(a$remove)) removes[[key(a$remove)]] <- a$remove
    for (a in acts) if (!is.null(a$add)) removes[[key(a$add)]] <- NULL
    for (a in acts) {
      d <- a$domainMetadata
      if (!is.null(d)) {
        if (isTRUE(d$removed)) domains[[d$domain]] <- NULL else domains[[d$domain]] <- d$configuration
      }
    }
  }
  list(removes = removes, domains = domains)
}

# A table in a temporary directory whose commit 0 is `lines`, exactly as
# written (no JSON writer in between, so numbers keep their digits).
raw_table <- function(lines, env = parent.frame()) {
  path <- file.path(withr::local_tempdir(.local_envir = env), "table")
  dir.create(file.path(path, "_delta_log"), recursive = TRUE)
  writeLines(lines, file.path(path, "_delta_log", "00000000000000000000.json"), useBytes = TRUE)
  path
}

# The protocol and metadata lines of a hand-written table with columns
# `columns` (named Delta types), as raw JSON text. A `timestamp_ntz` column
# comes with the reader feature it needs (#120).
raw_header <- function(columns = c(id = "long"), partition = character()) {
  fields <- paste0(
    sprintf('{\\"name\\":\\"%s\\",\\"type\\":\\"%s\\",\\"nullable\\":true,\\"metadata\\":{}}', names(columns), columns),
    collapse = ","
  )
  pcols <- if (length(partition)) paste0('"', partition, '"', collapse = ",") else ""
  protocol <- if ("timestamp_ntz" %in% columns) {
    '{"protocol":{"minReaderVersion":3,"minWriterVersion":7,"readerFeatures":["timestampNtz"],"writerFeatures":["timestampNtz"]}}'
  } else {
    '{"protocol":{"minReaderVersion":1,"minWriterVersion":2}}'
  }
  c(
    protocol,
    paste0(
      '{"metaData":{"id":"t","format":{"provider":"parquet","options":{}},"schemaString":"{\\"type\\":\\"struct\\",\\"fields\\":[',
      fields, ']}","partitionColumns":[', pcols, '],"configuration":{}}}'
    )
  )
}

`%||%` <- function(x, y) if (is.null(x)) y else x

# Which elements of an answer column are null: zujson gives a list for a
# column of objects and an atomic vector, with NA for null, otherwise.
answer_is_null <- function(x) {
  if (is.list(x)) vapply(x, is.null, NA) else is.na(x)
}

# ---- filters ---------------------------------------------------------------

# deltalake's live files at a version as a data frame `path` plus one typed
# column per partition column, typed from the answer's own Arrow schema.
oracle_partition_frame <- function(table, version) {
  aa <- oracle_field(table, version, "add_actions")
  type <- NULL
  for (s in aa$schema) if (s$name == "partition") type <- s$type
  out <- list(path = unlist(aa$columns$path))
  if (!is.null(type)) {
    inner <- sub("^struct<(.*)>$", "\\1", type)
    for (piece in strsplit(inner, ", ", fixed = TRUE)[[1L]]) {
      at <- regexpr(": [^:]*$", piece)
      name <- substr(piece, 1L, at - 1L)
      arrow <- substr(piece, at + 2L, nchar(piece))
      # A double as "%.17g", not as.character(), which writes 1.5 as "1,5"
      # under options(OutDec = ","); and with "." for the C library's
      # decimal point, which is "," under a comma LC_NUMERIC (#114).
      vals <- vapply(aa$columns$partition, function(p) {
        v <- p[[name]]
        if (is.null(v)) NA_character_ else if (is.double(v)) chartr(",", ".", sprintf("%.17g", v)) else as.character(v)
      }, "")
      out[[name]] <- switch(arrow,
        # An int32 of -2^31 is NA, as the read gives it (#118).
        int8 = , int16 = , int32 = suppressWarnings(as.integer(vals)),
        # Past 15 digits as text, which a filter compares exactly where a
        # double with no exact 15-digit form is refused.
        int64 = if (any(nchar(sub("^-", "", vals)) > 15L, na.rm = TRUE)) vals else as.numeric(vals),
        bool = as.logical(vals),
        float = , double = as.numeric(sub("^([+-]?)inf$", "\\1Inf", vals, ignore.case = TRUE)),
        `date32[day]` = as.Date(vals),
        vals
      )
    }
  }
  df <- as.data.frame(out, stringsAsFactors = FALSE, check.names = FALSE)
  df[order(df$path, method = "radix"), , drop = FALSE]
}

# deltalake's partitions() rows, with each float or double value (the
# text the log holds: "inf", "-inf", "NaN", "1.5") in the canonical
# spelling of the double it means ("Infinity", "-Infinity", "NaN"), as
# lake_partitions() returns it typed (#67); a float rounded through single
# precision, as deltalake reads it (#118); a time without its digits past
# the microsecond (#118), and with the "T" of the canonical form where the
# log's text has a space.
# `types` are the table's Delta types by column name.
oracle_partition_rows <- function(rows, types) {
  lapply(rows, function(r) {
    for (col in names(r)) {
      if (types[[col]] %in% c("float", "double") && is.character(r[[col]])) {
        r[[col]] <- as.numeric(sub("^([+-]?)inf$", "\\1Inf", r[[col]], ignore.case = TRUE))
        if (types[[col]] == "float" && is.finite(r[[col]])) {
          r[[col]] <- readBin(writeBin(r[[col]], raw(), size = 4L), "double", size = 4L)
        }
      }
      if (types[[col]] %in% c("timestamp", "timestamp_ntz") && is.character(r[[col]])) {
        # The log's text, which deltalake reads to the microsecond.
        r[[col]] <- sub("([.][0-9]{6})[0-9]+", "\\1", r[[col]])
        r[[col]] <- sub(" ", "T", r[[col]], fixed = TRUE)
      }
    }
    r
  })
}

filter_atom_calls <- c("==", "!=", "<", "<=", ">", ">=", "%in%", "is.na")

# A random filter over the partition columns of `parts` (and, rarely, a data
# column), of depth at most 3.
random_filter <- function(parts, data_cols, depth = 0L) {
  if (depth < 3L && stats::runif(1) < 0.45) {
    op <- sample(c("&", "|", "!"), 1L)
    if (op == "!") {
      return(call("!", random_filter(parts, data_cols, depth + 1L)))
    }
    return(call(op, random_filter(parts, data_cols, depth + 1L), random_filter(parts, data_cols, depth + 1L)))
  }
  cols <- setdiff(names(parts), "path")
  if (length(data_cols) && stats::runif(1) < 0.15) {
    return(call(">", as.symbol(data_cols[1L]), 0))
  }
  col <- sample(cols, 1L)
  values <- parts[[col]]
  pool <- unique(values[!is.na(values)])
  if (!length(pool)) pool <- values[1L]
  pick <- pool[sample.int(length(pool), 1L)]
  if (is.numeric(pick) && stats::runif(1) < 0.3) pick <- pick + sample(c(-1, 1), 1L)
  op <- sample(filter_atom_calls, 1L, prob = c(3, 2, 2, 2, 2, 2, 2, 1))
  sym <- as.symbol(col)
  if (op == "is.na") {
    return(call("is.na", sym))
  }
  if (op == "%in%") {
    set <- pool[sample.int(length(pool), min(length(pool), sample(1:3, 1L)))]
    if (stats::runif(1) < 0.3) set <- c(set, NA)
    return(call("%in%", sym, set))
  }
  if (stats::runif(1) < 0.2) call(op, pick, sym) else call(op, sym, pick)
}

# The paths a filter keeps, by brute force: each comparison on a data column
# can be TRUE, FALSE or NA on some row, so a file is kept when some choice of
# those makes R's evaluation on deltalake's partition values TRUE, in the
# oracles' locale whatever the session's (with_oracle_locale()).
oracle_filter_paths <- function(expr, parts, data_cols) {
  withr::local_locale(c(LC_COLLATE = "C", LC_CTYPE = session_ctype))
  atoms <- list()
  mark <- function(x) {
    if (is.call(x) && as.character(x[[1L]]) %in% filter_atom_calls &&
        length(intersect(all.names(x), data_cols))) {
      atoms[[length(atoms) + 1L]] <<- x
      return(as.symbol(paste0(".atom", length(atoms))))
    }
    if (is.call(x)) {
      for (i in seq_along(x)[-1L]) x[[i]] <- mark(x[[i]])
    }
    x
  }
  marked <- mark(expr)
  choices <- expand.grid(rep(list(c(TRUE, FALSE, NA)), length(atoms)))
  keep <- rep(FALSE, nrow(parts))
  for (k in seq_len(max(1L, nrow(choices)))) {
    env <- as.list(parts)
    for (j in seq_along(atoms)) env[[paste0(".atom", j)]] <- choices[[j]][k]
    r <- eval(marked, env, baseenv())
    keep <- keep | (rep_len(r, nrow(parts)) %in% TRUE)
  }
  parts$path[keep]
}

# An add action as raw JSON text; `stats` is the inner JSON already escaped
# for a JSON string, `size` and `partition` are written as given.
raw_add <- function(path, stats = NULL, size = "100", partition = "{}", extra = "") {
  paste0(
    '{"add":{"path":"', path, '","partitionValues":', partition, ',"size":', size,
    ',"modificationTime":0,"dataChange":true',
    if (!is.null(stats)) paste0(',"stats":"', stats, '"'), extra, '}}'
  )
}

# A table whose every 64-bit field holds the integer `text` (its digits, as
# written): commit 0 creates it, commit 1 has a commitInfo, a txn, a file
# with that partition value and statistics, and a removed file. Sizes,
# numRecords, nullCount and the deletion vector's cardinality hold `text`
# too unless it is negative, which the protocol does not allow for them.
int64_table <- function(text, env = parent.frame()) {
  path <- file.path(withr::local_tempdir(.local_envir = env), "table")
  log <- file.path(path, "_delta_log")
  dir.create(log, recursive = TRUE)
  count <- if (startsWith(text, "-")) "1" else text
  header <- raw_header(c(id = "long", p = "long"), partition = "p")
  header[1L] <- paste0(
    '{"protocol":{"minReaderVersion":3,"minWriterVersion":7,',
    '"readerFeatures":["deletionVectors"],"writerFeatures":["deletionVectors"]}}'
  )
  writeLines(c(header, raw_add("old.parquet", size = "1", partition = '{"p":"1"}')),
             file.path(log, "00000000000000000000.json"))
  q <- '\\"'
  stats <- sprintf("{%snumRecords%s:%s,%sminValues%s:{%sid%s:%s},%smaxValues%s:{%sid%s:%s},%snullCount%s:{%sid%s:%s}}",
                   q, q, count, q, q, q, q, text, q, q, q, q, text, q, q, q, q, count)
  dv <- sprintf(
    ',"deletionVector":{"storageType":"u","pathOrInlineDv":"vBn[lx{q8@P<9BNH/isA","offset":1,"sizeInBytes":36,"cardinality":%s}',
    count
  )
  writeLines(c(
    sprintf('{"commitInfo":{"timestamp":0,"operation":"WRITE","operationMetrics":{"n":%s}}}', text),
    sprintf('{"txn":{"appId":"app","version":%s}}', text),
    raw_add(sprintf("p=%s/a.parquet", text), stats = stats, size = count,
            partition = sprintf('{"p":"%s"}', text), extra = dv),
    sprintf('{"remove":{"path":"old.parquet","deletionTimestamp":0,"dataChange":true,"size":%s}}', count)
  ), file.path(log, "00000000000000000001.json"))
  path
}

# Filters (design sections 5 and 6, D8).
#
# A filter is an unevaluated R expression. Its pruning subset is comparisons
# (`==`, `!=`, `<`, `<=`, `>`, `>=`), `%in%` and `is.na()`, each between a
# column and values, joined by `!`, `&` and `|` (and parentheses). A value is
# any expression that names no column; it is evaluated once, in the caller's
# environment. A symbol that names a column is the column. Outside the
# subset, a filter may apply the row-wise functions of `row_wise_functions`
# to columns, and compare two columns; R evaluates those on rows after
# reading, and they never prune. Any other call with a column inside is
# refused (D8): a filter is decided row by row, so it gives the same rows
# however the table's rows are split into files.
#
# Each file gets the outcomes the filter can have on its rows (TRUE, FALSE or
# NA, as the filter evaluates on rows). A comparison on a partition column
# has the one outcome its rows share, from the file's partition value; a
# comparison on a data column has the outcomes its statistics allow
# (minimum, maximum, null count, record count); anything else can have any
# outcome. `!`, `&` and `|` combine the sets with R's three-valued logic. A
# file is kept when TRUE is possible, so no file whose rows could match is
# dropped, whatever the statistics say: they only decide what is read.
#
# Comparisons in the subset are made by the same code on partition values,
# on statistics and on rows (compare.R), so pruning and the row filter never
# disagree: long and decimal columns exactly, strings in UTF-8 byte order.

comparison_ops <- c("==", "!=", "<", "<=", ">", ">=")

# The comparison that is TRUE where `op` is FALSE (on non-NA values).
negate_op <- c(`==` = "!=", `!=` = "==", `<` = ">=", `<=` = ">", `>` = "<=", `>=` = "<")

# The comparison with its sides swapped: `v < x` is `x > v`.
flip_op <- c(`==` = "==", `!=` = "!=", `<` = ">", `<=` = ">=", `>` = "<", `>=` = "<=")

# Delta types of the snapshot's top-level columns, by logical name.
column_types <- function(tbl) {
  fields <- schema_fields(tbl)
  stats::setNames(vapply(fields, field_type, ""), vapply(fields, field_name, ""))
}

# Indexes of the snapshot's live files that `expr` keeps (all of them for a
# NULL filter). `strict` refuses anything outside the pruning subset, for
# lake_files() and lake_partitions(), which have no rows to filter.
filter_files <- function(tbl, expr, env, int64, strict = TRUE) {
  n <- nrow(tbl$files)
  if (is.null(expr)) {
    return(seq_len(n))
  }
  plan <- filter_plan(expr, column_types(tbl), env, strict)
  prune_files(tbl, plan, int64)
}

# Indexes of the live files `plan` keeps.
prune_files <- function(tbl, plan, int64) {
  n <- nrow(tbl$files)
  if (is.null(plan) || !n) {
    return(seq_len(n))
  }
  info <- prune_info(tbl, plan, int64)
  which(filter_outcomes(plan, info)$t)
}

filter_error <- function(expr, problem, strict = TRUE) {
  hint <- if (strict) {
    "A filter here is comparisons (==, !=, <, <=, >, >=), %in% and is.na() between a column and values, joined by !, & and |."
  } else {
    "A filter is comparisons (==, !=, <, <=, >, >=), %in% and is.na() between a column and values, and the row-wise functions listed in ?lake_read, joined by !, & and |."
  }
  zulake_abort(
    "filter",
    sprintf("`filter` cannot use %s: %s. %s", deparse_one(expr), problem, hint),
    expr = expr
  )
}

# ---- the plan ----------------------------------------------------------------

# Functions a filter may apply to columns, besides the pruning subset
# (design section 5, D8). Each gives one value per row, from that row alone,
# so a filter evaluated on each file's rows equals the filter evaluated on
# the whole table. They filter rows after reading and never prune.
row_wise_functions <- c(
  "+", "-", "*", "/", "%%", "%/%", "^", "abs", "round", "floor", "ceiling", "sqrt", "exp", "log",
  "nchar", "toupper", "tolower", "substr", "startsWith", "endsWith", "grepl", "is.nan", "is.finite",
  "xor", "as.character", "as.numeric", "as.integer"
)

# Arguments of a row-wise function that are options, not data: they must be
# values (no column inside), as R uses only their first element.
row_wise_options <- list(
  grepl = c("pattern", "ignore.case", "perl", "fixed", "useBytes"),
  nchar = c("type", "allowNA", "keepNA")
)

# Row-wise functions R defines as primitives, whose arguments are matched by
# position: for these, every argument after the first is an option.
row_wise_first_only <- c("as.character", "as.numeric", "as.integer")

# Row-wise functions that turn their first argument into text with
# as.character(), which before R 4.3.0 formatted a POSIXct vector with one
# format for all of it (no time when every value was at midnight, no
# fraction of a second): on a timestamp column their value for a row
# depended on the file's other rows, which is not row-wise (D8, #74).
time_text_functions <- c("as.character", "substr", "toupper", "tolower", "grepl")

# The running R's version; a function, so that tests can replace it.
r_version <- function() getRversion()

# Refuses, before R 4.3.0, a call of time_text_functions with a timestamp
# or timestamp_ntz column anywhere inside it.
check_time_text <- function(x, types, expr, strict) {
  if (r_version() >= "4.3.0") {
    return(invisible())
  }
  times <- names(types)[types %in% c("timestamp", "timestamp_ntz")]
  walk <- function(e) {
    if (!is.call(e)) {
      return(invisible())
    }
    name <- if (is.symbol(e[[1L]])) as.character(e[[1L]]) else ""
    if (name %in% time_text_functions) {
      col <- intersect(all.vars(e), times)
      if (length(col)) {
        filter_error(
          expr,
          sprintf(
            "%s() of the timestamp column %s is not row-wise before R 4.3.0, where a time's text depends on the other rows; compare the column with a time instead",
            name, format_string(col[1L])
          ),
          strict
        )
      }
    }
    for (a in as.list(e)[-1L]) walk(a)
  }
  walk(x)
}

# The filter checked against D8, with every value evaluated, as a tree of
# nodes:
#
#   list(op = "and" | "or" | "not", args)
#   list(op = "atom", fn, column, kind, type, keys, nan, has_na, has_nan,
#        call, columns)                    a column compared with values
#   list(op = "isna", column, columns)     is.na() of a column
#   list(op = "const", value)              a value: TRUE, FALSE or NA
#   list(op = "r", call, columns)          evaluated by R on rows: two
#                                          columns compared, a row-wise
#                                          function of columns, a column of
#                                          no kind compared, a logical
#                                          column
#
# `columns` lists the columns a node uses. `types` are the Delta types of
# the table's columns, by name. A call with a column inside it that is
# neither in the pruning subset nor row-wise is refused, never evaluated
# per file, since a per-file result would silently differ from the
# table's. `strict` refuses "r" and "const" nodes too, for lake_files()
# and lake_partitions(), which have no rows.
filter_plan <- function(expr, types, env, strict = TRUE) {
  columns <- names(types)
  has_column <- function(x) length(intersect(all.vars(x), columns)) > 0L
  row_node <- function(x, why) {
    check_time_text(x, types, expr, strict)
    call <- row_expr(x, columns, env, expr, strict)
    if (strict) {
      filter_error(expr, sprintf("%s, which filters rows and cannot prune files", why), strict = TRUE)
    }
    list(op = "r", call = call, columns = intersect(all.vars(call), columns))
  }
  const_node <- function(x) {
    if (strict) {
      filter_error(expr, "it names no column", strict = TRUE)
    }
    value <- filter_value(x, env, expr)
    if (!is.logical(value) || length(value) != 1L) {
      filter_error(expr, sprintf("%s names no column, so it must be one TRUE, FALSE or NA", deparse_one(x)), strict)
    }
    list(op = "const", value = value)
  }
  walk <- function(x) {
    if (!has_column(x)) {
      return(const_node(x))
    }
    if (is.symbol(x)) {
      col <- as.character(x)
      if (!identical(types[[col]], "boolean")) {
        filter_error(expr, sprintf("column %s is not logical; compare it with a value", format_string(col)), strict)
      }
      return(row_node(x, sprintf("the logical column %s alone", format_string(col))))
    }
    fn <- x[[1L]]
    name <- if (is.symbol(fn)) as.character(fn) else ""
    nargs <- length(x) - 1L
    if (name == "(" && nargs == 1L) {
      return(walk(x[[2L]]))
    }
    if (name == "!" && nargs == 1L) {
      return(list(op = "not", args = list(walk(x[[2L]]))))
    }
    if (name %in% c("&", "|") && nargs == 2L) {
      return(list(op = if (name == "&") "and" else "or", args = list(walk(x[[2L]]), walk(x[[3L]]))))
    }
    if (name == "%in%" && nargs == 2L && has_column(x[[3L]])) {
      filter_error(expr, "%in% takes a column on its left and values on its right", strict)
    }
    if (name %in% c(comparison_ops, "%in%") && nargs == 2L) {
      lhs <- x[[2L]]
      rhs <- x[[3L]]
      bare <- function(s) is.symbol(s) && as.character(s) %in% columns
      if (bare(lhs) && !has_column(rhs) || name != "%in%" && bare(rhs) && !has_column(lhs)) {
        return(atom_node(x, name, types, env, expr))
      }
      if (has_column(lhs) && has_column(rhs)) {
        return(row_node(x, "it compares two columns"))
      }
      return(row_node(x, "it compares a function of a column"))
    }
    if (name == "is.na" && nargs == 1L) {
      arg <- x[[2L]]
      if (is.symbol(arg)) {
        return(list(op = "isna", column = as.character(arg), columns = as.character(arg)))
      }
      return(row_node(x, "is.na() of a function of a column"))
    }
    if (name %in% row_wise_functions) {
      return(row_node(x, sprintf("%s() is row-wise", name)))
    }
    filter_error(expr, sprintf("%s is neither in the pruning subset nor row-wise", call_label(name)), strict)
  }
  walk(expr)
}

# An atom: column `x[[2]]` or `x[[3]]` (a bare column) compared with values.
atom_node <- function(x, name, types, env, expr) {
  columns <- names(types)
  lhs_col <- is.symbol(x[[2L]]) && as.character(x[[2L]]) %in% columns
  col <- as.character(if (lhs_col) x[[2L]] else x[[3L]])
  value <- filter_value(if (lhs_col) x[[3L]] else x[[2L]], env, expr)
  if (name != "%in%" && length(value) != 1L) {
    filter_error(expr, sprintf("a value compared with %s must have length 1", name), strict = TRUE)
  }
  call <- if (lhs_col) as.call(list(as.symbol(name), as.symbol(col), value)) else as.call(list(as.symbol(name), value, as.symbol(col)))
  fn_name <- if (lhs_col) name else flip_op[[name]]
  kind <- type_kind(types[[col]])
  if (is.na(kind)) {
    return(list(op = "r", call = call, columns = col))
  }
  lit <- literal_keys(value, kind, types[[col]], expr)
  keep <- !keys_na(lit$keys)
  list(
    op = "atom", fn = fn_name, column = col, kind = kind, type = types[[col]],
    keys = keys_subset(lit$keys, keep),
    has_na = any(!keep & !lit$nan), has_nan = any(lit$nan),
    call = call, columns = col
  )
}

# `x`, an expression R evaluates on rows, checked to be row-wise, with each
# value in it evaluated once in `env` and put in as a constant. A value
# there must have length 1, so that it means the same for every row, except
# the values on the right of %in%.
row_expr <- function(x, columns, env, expr, strict) {
  has_column <- function(e) length(intersect(all.vars(e), columns)) > 0L
  value_arg <- function(e, what) {
    if (has_column(e)) {
      filter_error(expr, sprintf("%s must be a value, with no column inside", what), strict)
    }
    v <- filter_value(e, env, expr)
    if (length(v) != 1L) {
      filter_error(expr, sprintf("%s has length %s; a value applied to rows must have length 1", deparse_one(e), format_number(length(v))), strict)
    }
    v
  }
  walk <- function(e) {
    if (!has_column(e)) {
      return(value_arg(e, deparse_one(e)))
    }
    if (is.symbol(e)) {
      return(e)
    }
    fn <- e[[1L]]
    name <- if (is.symbol(fn)) as.character(fn) else ""
    if (name == "%in%" && length(e) == 3L) {
      if (has_column(e[[3L]])) {
        filter_error(expr, "%in% takes a column on its left and values on its right", strict)
      }
      v <- filter_value(e[[3L]], env, expr)
      return(as.call(list(fn, walk(e[[2L]]), v)))
    }
    if (name %in% names(row_wise_options)) {
      e <- match.call(get(name, envir = baseenv()), e)
      args <- as.list(e)[-1L]
      for (a in seq_along(args)) {
        arg <- names(args)[a]
        e[[a + 1L]] <- if (arg %in% row_wise_options[[name]]) {
          value_arg(args[[a]], sprintf("argument `%s` of %s()", arg, name))
        } else {
          walk(args[[a]])
        }
      }
      e[[1L]] <- fn
      return(e)
    }
    if (name %in% row_wise_first_only) {
      for (a in seq_len(length(e) - 1L)) {
        e[[a + 1L]] <- if (a == 1L) walk(e[[2L]]) else value_arg(e[[a + 1L]], sprintf("an option of %s()", name))
      }
      return(e)
    }
    if (name %in% c(row_wise_functions, comparison_ops, "(", "!", "&", "|", "is.na")) {
      for (a in seq_len(length(e) - 1L)) {
        if (!identical(e[[a + 1L]], quote(expr = ))) {
          e[[a + 1L]] <- walk(e[[a + 1L]])
        }
      }
      return(e)
    }
    filter_error(expr, sprintf("%s is applied to a column but is not row-wise", call_label(name)), strict)
  }
  walk(x)
}

# A value: an expression that names no column, evaluated once in `env`.
filter_value <- function(x, env, expr) {
  value <- tryCatch(eval(x, env), error = function(e) {
    filter_error(expr, sprintf("evaluating %s failed (%s)", deparse_one(x), conditionMessage(e)), strict = FALSE)
  })
  if (!is.atomic(value) || is.null(value)) {
    filter_error(expr, "a value must be a vector", strict = FALSE)
  }
  value
}

call_label <- function(name) {
  if (nzchar(name)) paste0(name, "()") else "that call"
}

deparse_one <- function(x) {
  paste(deparse(x, width.cutoff = 60L), collapse = " ")
}

# Columns a plan uses.
plan_columns <- function(plan) {
  if (is.null(plan)) {
    return(character())
  }
  if (plan$op %in% c("and", "or", "not")) {
    return(unique(unlist(lapply(plan$args, plan_columns))))
  }
  plan$columns
}

# ---- one node on values ---------------------------------------------------------

# An atom or is.na() node on a column's values `x` (rows of a piece, or one
# partition value per file): TRUE, FALSE or NA per value.
atom_values <- function(node, x) {
  n <- length(x)
  if (node$op == "isna") {
    return(if (is.list(x)) vapply(x, is.null, NA) else is.na(x))
  }
  keys <- column_keys(x, node$kind, node$type)
  if (node$fn == "%in%") {
    out <- rep(FALSE, n)
    for (j in seq_len(keys_length(node$keys))) {
      out <- out | (keys_cmp(keys, keys_subset(node$keys, j), node$kind) %in% 0L)
    }
    nan <- if (is.double(x) && !inherits(x, "integer64")) is.nan(x) else rep(FALSE, n)
    out[is.na(x) & !nan] <- node$has_na
    out[nan] <- node$has_nan
    return(out)
  }
  if (!keys_length(node$keys)) {
    return(rep(NA, n))
  }
  op_sign(keys_cmp(keys, node$keys, node$kind), node$fn)
}

# A comparison's result from -1, 0, 1 (NA stays NA).
op_sign <- function(c, op) {
  switch(op,
    `==` = c == 0L,
    `!=` = c != 0L,
    `<` = c < 0L,
    `<=` = c <= 0L,
    `>` = c > 0L,
    `>=` = c >= 0L
  )
}

# ---- rows -----------------------------------------------------------------------

# The filter on the rows of `data` (a data frame of the columns it uses):
# TRUE, FALSE or NA per row. Nodes R evaluates see the columns first, then
# `env`.
filter_rows <- function(plan, data, env) {
  n <- nrow(data)
  switch(plan$op,
    not = !filter_rows(plan$args[[1L]], data, env),
    and = filter_rows(plan$args[[1L]], data, env) & filter_rows(plan$args[[2L]], data, env),
    or = filter_rows(plan$args[[1L]], data, env) | filter_rows(plan$args[[2L]], data, env),
    const = rep(plan$value, n),
    atom = ,
    isna = atom_values(plan, data[[plan$column]]),
    r = {
      # Values are already in the call, so the only names left are columns
      # and functions, which are base R's, whatever the caller defines.
      r <- tryCatch(
        eval(plan$call, as.list(data[plan$columns]), baseenv()),
        error = function(e) {
          filter_error(plan$call, sprintf("evaluating it on rows failed (%s)", conditionMessage(e)), strict = FALSE)
        }
      )
      if (!is.logical(r) || length(r) != n || !is.null(dim(r))) {
        filter_error(plan$call, "it does not give one TRUE, FALSE or NA per row", strict = FALSE)
      }
      as.vector(r)
    }
  )
}

# ---- pruning --------------------------------------------------------------------

# What pruning needs to know about the live files, for the columns `plan`
# uses: `n` files; `part`, the partition values as atoms compare them
# (decimal text for long and decimal columns, typed otherwise); and `stats`,
# per data column, what the statistics allow.
prune_info <- function(tbl, plan, int64) {
  actions <- tbl$files$action
  n <- length(actions)
  types <- column_types(tbl)
  pcols <- tbl$metadata[["partitionColumns"]]
  used <- plan_columns(plan)
  info <- list(n = n, partition = pcols, part = list(), stats = list())
  for (col in intersect(used, pcols)) {
    raw <- partition_raw(actions, tbl, col)
    kind <- type_kind(types[[col]])
    info$part[[col]] <- if (!is.na(kind) && kind == "exact") raw else parse_partition_values(raw, types[[col]], int64, col)
  }
  data_cols <- setdiff(used, pcols)
  if (length(data_cols)) {
    parsed <- parse_stats(file_stats_text(actions), tbl$files$path)
    for (col in data_cols) {
      info$stats[[col]] <- column_bounds(tbl, parsed, col, types[[col]])
    }
  }
  info
}

file_stats_text <- function(actions) {
  vapply(actions, function(a) {
    s <- a[["stats"]]
    if (is_string(s)) s else NA_character_
  }, "", USE.NAMES = FALSE)
}

# Whether each of `n` files can make the filter TRUE (`t`) and FALSE (`f`)
# on some row. NA needs no tracking: under R's three-valued logic `!x` is
# TRUE only where `x` is FALSE, `x & y` only where both are TRUE and `x | y`
# where either is, and FALSE likewise, so an NA outcome never leads to TRUE.
filter_outcomes <- function(plan, info) {
  n <- info$n
  any_outcome <- list(t = rep(TRUE, n), f = rep(TRUE, n))
  switch(plan$op,
    not = {
      a <- filter_outcomes(plan$args[[1L]], info)
      list(t = a$f, f = a$t)
    },
    and = {
      a <- filter_outcomes(plan$args[[1L]], info)
      b <- filter_outcomes(plan$args[[2L]], info)
      list(t = a$t & b$t, f = a$f | b$f)
    },
    or = {
      a <- filter_outcomes(plan$args[[1L]], info)
      b <- filter_outcomes(plan$args[[2L]], info)
      list(t = a$t | b$t, f = a$f & b$f)
    },
    atom = ,
    isna = {
      if (plan$column %in% info$partition) {
        r <- atom_values(plan, info$part[[plan$column]])
        return(list(t = r %in% TRUE, f = r %in% FALSE))
      }
      bounds <- info$stats[[plan$column]]
      if (is.null(bounds)) any_outcome else stats_outcomes(plan, bounds)
    },
    const = list(t = rep(plan$value %in% TRUE, n), f = rep(plan$value %in% FALSE, n)),
    # A node R evaluates on rows never prunes, on partition columns too.
    r = any_outcome
  )
}

# ---- statistics -----------------------------------------------------------------

# What the statistics of each file allow for data column `col` of Delta type
# `type`: `lo` and `hi` as keys of the column's kind (NA where unknown),
# `hi_prefix` (a string maximum, which a writer may have truncated, so the
# true maximum can be any string that starts with it), and whether a null,
# a non-null and a NaN value can occur.
column_bounds <- function(tbl, parsed, col, type) {
  n <- length(parsed)
  kind <- type_kind(type)
  fields <- schema_fields(tbl)
  field <- fields[[match(col, vapply(fields, field_name, ""))]]
  key <- field_physical(field, tbl$column_mapping)
  get <- function(i, what) {
    obj <- parsed[[i]][[what]]
    if (is.list(obj) && !is.null(names(obj))) obj[[key]] else NULL
  }
  leaf_text <- function(v) {
    if (is.null(v) || is.list(v) || length(v) != 1L) NA_character_ else if (is_marked(v)) marked_text(v) else if (is.character(v)) v else if (is.logical(v) && !is.na(v)) if (v) "1" else "0" else NA_character_
  }
  count_text <- function(v) {
    t <- leaf_text(v)
    if (is_marked(v) && grepl("^[0-9]+$", t)) t else NA_character_
  }
  nrec <- vapply(seq_len(n), function(i) {
    v <- parsed[[i]][["numRecords"]]
    if (is.null(v)) NA_character_ else count_text(v)
  }, "")
  nulls <- vapply(seq_len(n), function(i) count_text(get(i, "nullCount")), "")
  lo_text <- vapply(seq_len(n), function(i) leaf_text(get(i, "minValues")), "")
  hi_text <- vapply(seq_len(n), function(i) leaf_text(get(i, "maxValues")), "")
  nrec_p <- exact_parse(nrec)
  nulls_p <- exact_parse(nulls)
  empty <- exact_cmp(nrec_p, exact_parse("0")) %in% 0L
  null_possible <- !empty & !(exact_cmp(nulls_p, exact_parse("0")) %in% 0L)
  nonnull_possible <- !empty & !(exact_cmp(nulls_p, nrec_p) %in% c(0L, 1L))
  out <- list(
    null = null_possible, nonnull = nonnull_possible,
    nan = nonnull_possible & type %in% c("float", "double"),
    hi_prefix = FALSE
  )
  if (is.na(kind)) {
    return(c(out, list(kind = NA_character_)))
  }
  out$kind <- kind
  if (kind == "exact") {
    ok <- function(t) {
      good <- is_exact_text(t)
      ps <- decimal_ps(type)
      if (!is.null(ps)) {
        # deltalake writes decimal statistics through a double, so one with
        # more fraction digits than the scale is not the column's value; and
        # past 15 digits a double holds no decimal exactly.
        good <- good & ps[["precision"]] <= max_double_precision &
          exact_fraction_digits(exact_parse(ifelse(good, t, NA))) <= ps[["scale"]]
      }
      ifelse(good, t, NA_character_)
    }
    out$lo <- exact_parse(ok(lo_text))
    out$hi <- exact_parse(ok(hi_text))
    if (type == "integer") {
      # qio reads an int32 of -2^31 as NA, R's integer NA, where the null
      # count does not count it: a file may hold such an NA unless its
      # minimum is known and above -2^31 (#79).
      above <- exact_cmp(out$lo, exact_parse("-2147483648")) %in% 1L
      out$null <- out$null | (out$nonnull & !above)
    }
  } else if (kind == "number") {
    num <- function(t) {
      x <- switch(type,
        date = as.numeric(unclass(parse_date_text(t))),
        timestamp = as.numeric(unclass(parse_time_text(t, zone = TRUE))),
        timestamp_ntz = as.numeric(unclass(parse_time_text(t, zone = FALSE))),
        ifelse(is_exact_text(t), suppressWarnings(as.numeric(t)), NA_real_)
      )
      x[is.nan(x)] <- NA_real_
      x
    }
    lo <- num(lo_text)
    hi <- num(hi_text)
    if (type == "float") {
      # A float statistic is written as the shortest decimal that reads back
      # as the float, which as a double can sit up to half a float step from
      # the float's own value.
      lo <- lo - pmax(abs(lo) * 2^-23, 2^-149)
      hi <- hi + pmax(abs(hi) * 2^-23, 2^-149)
    }
    if (type %in% c("timestamp", "timestamp_ntz")) {
      # Writers truncate timestamp statistics to milliseconds.
      lo <- lo - 0.001
      hi <- hi + 0.001
    }
    out$lo <- lo
    out$hi <- hi
  } else {
    out$lo <- ifelse(is.na(lo_text), NA_character_, enc2utf8(lo_text))
    # Delta Spark ends a truncated maximum with U+FFFD as a tie-breaker,
    # which sorts below every supplementary character in UTF-8 byte order:
    # the prefix is what comes before it (#78).
    hi_text <- ifelse(is.na(hi_text), NA_character_, sub("\uFFFD+$", "", enc2utf8(hi_text)))
    out$hi <- hi_text
    out$hi_prefix <- TRUE
  }
  out
}

# Outcomes of an atom or is.na() node on a data column, from its bounds.
stats_outcomes <- function(node, b) {
  if (node$op == "isna") {
    return(list(t = b$null | b$nan, f = b$nonnull))
  }
  if (is.na(b$kind)) {
    return(list(t = rep(TRUE, length(b$null)), f = rep(TRUE, length(b$null))))
  }
  known <- !keys_na(b$lo) & !keys_na(b$hi)
  # Whether some value in [lo, hi] makes `op` TRUE against key `v`.
  possible <- function(op, v) {
    lo <- keys_cmp(b$lo, v, b$kind)
    hi <- if (b$hi_prefix) {
      ifelse(bytes_starts_with(rep_len(v, length(b$hi)), b$hi), 1L, bytes_cmp(b$hi, v))
    } else {
      keys_cmp(b$hi, v, b$kind)
    }
    r <- switch(op,
      `==` = lo <= 0L & hi >= 0L,
      `!=` = !(lo == 0L & hi == 0L),
      `<` = lo < 0L,
      `<=` = lo <= 0L,
      `>` = hi > 0L,
      `>=` = hi >= 0L
    )
    r[!known] <- TRUE
    r
  }
  if (node$fn == "%in%") {
    t <- (b$null & node$has_na) | (b$nan & node$has_nan)
    f <- (b$null & !node$has_na) | (b$nan & !node$has_nan)
    in_range <- rep(FALSE, length(known))
    all_equal <- rep(FALSE, length(known))
    for (j in seq_len(keys_length(node$keys))) {
      v <- keys_subset(node$keys, j)
      in_range <- in_range | possible("==", v)
      all_equal <- all_equal | !possible("!=", v)
    }
    return(list(t = t | (b$nonnull & in_range), f = f | (b$nonnull & !all_equal)))
  }
  if (!keys_length(node$keys)) {
    none <- rep(FALSE, length(known))
    return(list(t = none, f = none))
  }
  list(
    t = b$nonnull & possible(node$fn, node$keys),
    f = b$nonnull & possible(negate_op[[node$fn]], node$keys)
  )
}

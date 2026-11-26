# Filters (design sections 5 and 6, D8).
#
# A filter is an unevaluated R expression. Its pruning subset is comparisons
# (`==`, `!=`, `<`, `<=`, `>`, `>=`), `%in%` and `is.na()`, each between a
# column and values, joined by `!`, `&` and `|` (and parentheses). A value is
# any expression that names no column; it is evaluated once, in the caller's
# environment. A symbol that names a column is the column.
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

filter_error <- function(expr, problem) {
  zulake_abort(
    "filter",
    sprintf(
      "`filter` cannot use %s: %s. A filter here is comparisons (==, !=, <, <=, >, >=), %%in%% and is.na() on columns, joined by !, & and |.",
      paste(deparse(expr, width.cutoff = 60L), collapse = " "), problem
    ),
    expr = expr
  )
}

# ---- the plan ----------------------------------------------------------------

# The filter checked against the pruning subset, with every value evaluated,
# as a tree of nodes:
#
#   list(op = "and" | "or" | "not", args)
#   list(op = "atom", fn, column, kind, type, keys, nan, has_na, has_nan,
#        call, columns)                    a column compared with values
#   list(op = "isna", column, columns)     is.na() of a column
#   list(op = "r", call, columns)          evaluated by R: two columns
#                                          compared, a column of no kind, or
#                                          (unless `strict`) anything outside
#                                          the subset
#
# `columns` lists the columns a node uses. `types` are the Delta types of
# the table's columns, by name.
filter_plan <- function(expr, types, env, strict = TRUE) {
  columns <- names(types)
  r_node <- function(why) {
    if (strict) {
      filter_error(expr, why)
    }
    list(op = "r", call = expr, columns = intersect(all.vars(expr), columns))
  }
  if (is.call(expr)) {
    fn <- expr[[1L]]
    name <- if (is.symbol(fn)) as.character(fn) else ""
    nargs <- length(expr) - 1L
    if (name == "(" && nargs == 1L) {
      return(filter_plan(expr[[2L]], types, env, strict))
    }
    if (name == "!" && nargs == 1L) {
      return(list(op = "not", args = list(filter_plan(expr[[2L]], types, env, strict))))
    }
    if (name %in% c("&", "|") && nargs == 2L) {
      return(list(
        op = if (name == "&") "and" else "or",
        args = list(filter_plan(expr[[2L]], types, env, strict), filter_plan(expr[[3L]], types, env, strict))
      ))
    }
    if (name %in% c(comparison_ops, "%in%") && nargs == 2L) {
      lhs <- filter_operand(expr[[2L]], columns, env, expr, strict)
      rhs <- filter_operand(expr[[3L]], columns, env, expr, strict)
      if (is.null(lhs) || is.null(rhs)) {
        return(r_node("a column is inside a value"))
      }
      if (is.null(lhs$column) && is.null(rhs$column)) {
        return(r_node("it compares no column"))
      }
      if (name != "%in%") {
        for (side in list(lhs, rhs)) {
          if (is.null(side$column) && length(side$value) != 1L) {
            return(r_node(sprintf("a value compared with %s must have length 1", name)))
          }
        }
      }
      call <- as.call(list(as.symbol(name), lhs$expr, rhs$expr))
      used <- c(lhs$column, rhs$column)
      if (length(used) == 2L || (name == "%in%" && is.null(lhs$column))) {
        return(list(op = "r", call = call, columns = unique(used)))
      }
      col <- used
      value <- if (is.null(lhs$column)) lhs$value else rhs$value
      fn_name <- if (name != "%in%" && is.null(lhs$column)) flip_op[[name]] else name
      kind <- type_kind(types[[col]])
      if (is.na(kind)) {
        return(list(op = "r", call = call, columns = col))
      }
      lit <- literal_keys(value, kind, types[[col]], expr)
      keep <- !keys_na(lit$keys)
      return(list(
        op = "atom", fn = fn_name, column = col, kind = kind, type = types[[col]],
        keys = keys_subset(lit$keys, keep),
        has_na = any(!keep & !lit$nan), has_nan = any(lit$nan),
        call = call, columns = col
      ))
    }
    if (name == "is.na" && nargs == 1L) {
      arg <- expr[[2L]]
      if (!is.symbol(arg) || !as.character(arg) %in% columns) {
        return(r_node("is.na() takes a column"))
      }
      return(list(op = "isna", column = as.character(arg), columns = as.character(arg)))
    }
    return(r_node(sprintf("%s is not in the pruning subset", if (nzchar(name)) paste0(name, "()") else "that call")))
  }
  r_node("it is not a comparison")
}

# A comparison operand: a column (its symbol), or a value with no column in
# it, evaluated in `env` and put in the call as a constant. NULL, unless
# `strict`, for a value with a column inside it.
filter_operand <- function(x, columns, env, expr, strict) {
  if (is.symbol(x) && as.character(x) %in% columns) {
    return(list(column = as.character(x), expr = x))
  }
  used <- intersect(all.names(x), columns)
  if (length(used)) {
    if (!strict) {
      return(NULL)
    }
    filter_error(expr, sprintf("column %s is inside a value", format_string(used[1L])))
  }
  value <- tryCatch(eval(x, env), error = function(e) {
    filter_error(expr, sprintf("evaluating %s failed (%s)", paste(deparse(x), collapse = " "), conditionMessage(e)))
  })
  if (!is.atomic(value) || is.null(value)) {
    filter_error(expr, "a value must be a vector")
  }
  list(column = NULL, expr = value, value = value)
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
    atom = ,
    isna = atom_values(plan, data[[plan$column]]),
    r = {
      r <- eval(plan$call, as.list(data), env)
      if (!is.logical(r) || !(length(r) %in% c(1L, n))) {
        filter_error(plan$call, "it does not give one TRUE, FALSE or NA per row")
      }
      rep_len(r, n)
    }
  )
}

# ---- pruning --------------------------------------------------------------------

# What pruning needs to know about the live files, for the columns `plan`
# uses: `n` files; `part`, the partition values as atoms compare them
# (decimal text for long and decimal columns, typed otherwise); `part_rows`,
# typed as a read returns them (or NULL when that fails), for the nodes R
# evaluates; and `stats`, per data column, what the statistics allow.
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
  info$part_rows <- tryCatch(
    partition_read_table(actions, tbl, int64, intersect(used, pcols)),
    error = function(e) NULL
  )
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
    r = {
      if (!all(plan$columns %in% info$partition) || is.null(info$part_rows)) {
        return(any_outcome)
      }
      r <- tryCatch(eval(plan$call, as.list(info$part_rows), baseenv()), error = function(e) NULL)
      if (!is.logical(r) || !(length(r) %in% c(1L, n))) {
        return(any_outcome)
      }
      r <- rep_len(r, n)
      list(t = r %in% TRUE, f = r %in% FALSE)
    }
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
    out$hi <- ifelse(is.na(hi_text), NA_character_, enc2utf8(hi_text))
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

# Filters over files (design sections 5 and 6, D8).
#
# A filter is an unevaluated R expression. Its pruning subset is comparisons
# (`==`, `!=`, `<`, `<=`, `>`, `>=`), `%in%` and `is.na()`, each between a
# column and values, joined by `!`, `&` and `|` (and parentheses). A value is
# any expression that names no column; it is evaluated once, in the caller's
# environment. A symbol that names a column is the column.
#
# Each file gets the outcomes the filter can have on its rows (TRUE, FALSE or
# NA, as R evaluates the expression). A comparison on partition
# columns only has one outcome per file, the one R gives on the file's
# partition values. A comparison that involves another column can have any
# outcome until statistics are used (Stage 4). `!`, `&` and `|` combine the
# sets with R's three-valued logic. A file is kept when TRUE is possible, so
# no file whose rows could match is dropped.

comparison_ops <- c("==", "!=", "<", "<=", ">", ">=")

# Indexes of the snapshot's live files that `expr` keeps (all of them for a
# NULL filter).
filter_files <- function(tbl, expr, env, int64) {
  n <- nrow(tbl$files)
  if (is.null(expr)) {
    return(seq_len(n))
  }
  columns <- vapply(schema_fields(tbl), field_name, "")
  parts <- partition_table(tbl$files$action, tbl, int64)
  for (col in names(parts)) {
    if (grepl("^decimal", partition_type(tbl, col))) {
      parts[[col]] <- as.numeric(parts[[col]])
    }
  }
  plan <- filter_plan(expr, columns, env)
  out <- filter_outcomes(plan, parts, n)
  which(out$t)
}

partition_type <- function(tbl, col) {
  fields <- schema_fields(tbl)
  field_type(fields[[match(col, vapply(fields, field_name, ""))]])
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

# The filter checked against the pruning subset, with every value evaluated:
# a tree of list(op = "and" | "or" | "not", args) and list(op = "atom", call,
# columns).
filter_plan <- function(expr, columns, env) {
  if (is.call(expr)) {
    fn <- expr[[1L]]
    name <- if (is.symbol(fn)) as.character(fn) else ""
    nargs <- length(expr) - 1L
    if (name == "(" && nargs == 1L) {
      return(filter_plan(expr[[2L]], columns, env))
    }
    if (name == "!" && nargs == 1L) {
      return(list(op = "not", args = list(filter_plan(expr[[2L]], columns, env))))
    }
    if (name %in% c("&", "|") && nargs == 2L) {
      return(list(
        op = if (name == "&") "and" else "or",
        args = list(filter_plan(expr[[2L]], columns, env), filter_plan(expr[[3L]], columns, env))
      ))
    }
    if (name %in% c(comparison_ops, "%in%") && nargs == 2L) {
      lhs <- filter_operand(expr[[2L]], columns, env, expr)
      rhs <- filter_operand(expr[[3L]], columns, env, expr)
      if (is.null(lhs$column) && is.null(rhs$column)) {
        filter_error(expr, "it compares no column")
      }
      if (name != "%in%") {
        for (side in list(lhs, rhs)) {
          if (is.null(side$column) && length(side$value) != 1L) {
            filter_error(expr, sprintf("a value compared with %s must have length 1", name))
          }
        }
      }
      call <- as.call(list(as.symbol(name), lhs$expr, rhs$expr))
      return(list(op = "atom", call = call, columns = c(lhs$column, rhs$column)))
    }
    if (name == "is.na" && nargs == 1L) {
      arg <- expr[[2L]]
      if (!is.symbol(arg) || !as.character(arg) %in% columns) {
        filter_error(expr, "is.na() takes a column")
      }
      return(list(op = "atom", call = expr, columns = as.character(arg)))
    }
    filter_error(expr, sprintf("%s is not in the pruning subset", if (nzchar(name)) paste0(name, "()") else "that call"))
  }
  filter_error(expr, "it is not a comparison")
}

# A comparison operand: a column (its symbol), or a value with no column in
# it, evaluated in `env` and put in the call as a constant.
filter_operand <- function(x, columns, env, expr) {
  if (is.symbol(x) && as.character(x) %in% columns) {
    return(list(column = as.character(x), expr = x))
  }
  used <- intersect(all.names(x), columns)
  if (length(used)) {
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

# Whether each of `n` files can make the filter TRUE (`t`) and FALSE (`f`)
# on some row. NA needs no tracking: under R's three-valued logic `!x` is
# TRUE only where `x` is FALSE, `x & y` only where both are TRUE and `x | y`
# where either is, and FALSE likewise, so an NA outcome never leads to TRUE.
filter_outcomes <- function(plan, parts, n) {
  switch(plan$op,
    not = {
      a <- filter_outcomes(plan$args[[1L]], parts, n)
      list(t = a$f, f = a$t)
    },
    and = {
      a <- filter_outcomes(plan$args[[1L]], parts, n)
      b <- filter_outcomes(plan$args[[2L]], parts, n)
      list(
        t = a$t & b$t,
        f = a$f | b$f
      )
    },
    or = {
      a <- filter_outcomes(plan$args[[1L]], parts, n)
      b <- filter_outcomes(plan$args[[2L]], parts, n)
      list(
        t = a$t | b$t,
        f = a$f & b$f
      )
    },
    atom = {
      if (!all(plan$columns %in% names(parts))) {
        return(list(t = rep(TRUE, n), f = rep(TRUE, n)))
      }
      r <- eval(plan$call, as.list(parts), baseenv())
      if (!is.logical(r) || length(r) != n) {
        filter_error(plan$call, "it does not give one TRUE, FALSE or NA per file")
      }
      list(t = r %in% TRUE, f = r %in% FALSE)
    }
  )
}

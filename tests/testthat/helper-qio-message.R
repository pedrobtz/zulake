# The decimal-as-double message qio emits. qio from pedrobtz/qio#75 on
# signals it with class `qio_message_decimal_double` and a `columns` data
# frame (path, physical_type, precision, scale); older qio sends plain
# text. Both are built here as qio sends them, so the test runs whatever
# qio is installed.

qio_decimal_condition <- function(precision) {
  structure(
    class = c("qio_message_decimal_double", "message", "condition"),
    list(
      message = "Reading Parquet DECIMAL columns as double; values may be inexact.\n",
      call = NULL,
      columns = data.frame(
        path = paste0("d", seq_along(precision)),
        physical_type = "INT64",
        precision = as.integer(precision),
        scale = 2L
      )
    )
  )
}

signal_through_muffler <- function(cond, vetted) {
  shown <- FALSE
  withCallingHandlers(
    withCallingHandlers(message(cond), message = qio_decimal_muffler(vetted)),
    message = function(m) {
      shown <<- TRUE
      invokeRestart("muffleMessage")
    }
  )
  shown
}

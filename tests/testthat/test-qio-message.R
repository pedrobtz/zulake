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

test_that("the classed qio message is muffled when every column is 15 digits or fewer", {
  expect_false(signal_through_muffler(qio_decimal_condition(c(7, 15)), vetted = FALSE))
})

test_that("the classed qio message is kept when a column is wider than 15 digits", {
  expect_true(signal_through_muffler(qio_decimal_condition(c(7, 16)), vetted = TRUE))
})

test_that("the unclassed message of qio 0.1.x is muffled only when zulake vetted the read", {
  old <- simpleMessage("Reading 2 Parquet DECIMAL columns as double; values may be inexact.\n")
  expect_false(signal_through_muffler(old, vetted = TRUE))
  expect_true(signal_through_muffler(old, vetted = FALSE))
})

test_that("other messages pass through", {
  other <- simpleMessage("something else\n")
  expect_true(signal_through_muffler(other, vetted = TRUE))
  other_cls <- structure(class = c("qio_message_other", "message", "condition"),
                         list(message = "Parquet DECIMAL columns as double\n", call = NULL))
  expect_true(signal_through_muffler(other_cls, vetted = FALSE))
})

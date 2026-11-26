# Helpers are in helper-qio-message.R: the suite is shuffled per
# top-level expression, so test files hold only test_that() blocks.

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

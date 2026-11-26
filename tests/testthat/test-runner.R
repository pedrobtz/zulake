# tests/testthat.R sets the printed seed, then runs every file with
# shuffle = TRUE. These check that composition: one seed gives one order,
# every time, and the order is shuffled. run_order() is in helper-runner.R.

test_that("a shuffled run repeats its order under the same seed", {
  first <- run_order(20261126L)
  expect_setequal(first, 1:20)
  expect_identical(run_order(20261126L), first)
})

test_that("a shuffled run does not keep the file's order", {
  expect_identical(run_order(20261126L, shuffle = FALSE), 1:20)
  expect_false(identical(run_order(20261126L), 1:20))
  expect_false(identical(run_order(20261126L), run_order(1L)))
})

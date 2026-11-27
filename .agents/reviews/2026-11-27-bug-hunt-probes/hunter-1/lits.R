lits <- list(
  `1L` = 1L, `0` = 0, `1.5` = 1.5, `0.1` = 0.1, `-1` = -1, big31 = 2^31, big53 = 2^53, big53p = 2^53 + 2, `1e300` = 1e300,
  i32max = .Machine$integer.max, Inf_ = Inf, mInf = -Inf, NaN_ = NaN, NAr = NA_real_, NAi = NA_integer_, NAc = NA_character_, NAl = NA,
  T = TRUE, F = FALSE, sa = "a", sbbb = "bbb", sZ = "Z", se = "é", snum = "1", snum2 = "12.30", snum3 = "0.10", sempty = "",
  semoji = "\U0001F600", snl = "x\ny", slat = { x <- "\xe9"; Encoding(x) <- "latin1"; x }, a40 = strrep("a", 40), a40z = paste0(strrep("a", 40), "z"),
  date = as.Date("2024-01-31"), date2 = as.Date("1970-01-01"), sdate = "2024-01-31", sdate2 = "2024-02-29",
  px = as.POSIXct("2024-01-31 12:00:00.123456", tz = "UTC"), pxz = as.POSIXct("2024-03-10 10:00:00", tz = "UTC"),
  pxny = as.POSIXct("2024-03-10 05:00:00", tz = "America/New_York"),
  sts = "2024-03-10 10:00:00", sts2 = "2024-06-15 12:00:00.999999", sts3 = "2024-01-31T12:00:00.123456Z", sts4 = "2024-03-10T11:00:00+01:00",
  sts5 = "1969-12-31 23:59:59.999999", sts6 = "2024-06-15 12:00:00.5", sts7 = "1970-01-01 00:00:00.000001",
  fac = factor("a"), i64s = "9007199254740993", i64max = "9223372036854775807", i64min = "-9223372036854775808",
  dec1 = 12.3, dec2 = 99999999.99, dec3 = 0.00001, dec4 = 1234567890.12345, f32a = 0.10000000149011612, f32m = 3.4028234663852886e+38,
  f32b = 16777217, f32c = 16777216, tiny = 5e-324, f32tiny = 1.401298464324817e-45, m0 = -0.0
)
mk_exprs <- function(col, v) {
  ops <- c("==", "!=", "<", "<=", ">", ">=")
  c(
    lapply(ops, function(op) as.call(list(as.symbol(op), as.symbol(col), v))),
    lapply(ops, function(op) as.call(list(as.symbol(op), v, as.symbol(col)))),
    list(as.call(list(as.symbol("%in%"), as.symbol(col), v)),
         call("!", as.call(list(as.symbol("%in%"), as.symbol(col), v))),
         call("!", as.call(list(as.symbol("=="), as.symbol(col), v))),
         call("!", as.call(list(as.symbol("<"), as.symbol(col), v))),
         call("|", as.call(list(as.symbol(">"), as.symbol(col), v)), call("is.na", as.symbol(col))))
  )
}

source(file.path(Sys.getenv("W"), "common.R"))
tbl <- lake_open(file.path(W, "t/types"))
full <- suppressWarnings(lake_read(tbl))
invisible(Sys.setlocale("LC_COLLATE", "C"))
chk <- function(e, env = parent.frame()) {
  a <- try1(eval(bquote(lake_read(tbl, filter = .(e))), env))
  r <- try1({ x <- eval(e, full, env); full[x %in% TRUE, , drop = FALSE] })
  st <- if (is_err(a)) paste("ERR", substr(a$msg, 1, 150)) else if (same_df(a, r)) "ok" else paste("DIFF got", paste(a$a, collapse = ","), "| ref", if (is_err(r)) r$msg else paste(r$a, collapse = ","))
  cat(sprintf("%-50s %s\n", paste(deparse(e, width.cutoff = 200), collapse = ""), st))
}
x <- 2; a_local <- 5; nchar <- function(...) 99; s2 <- "a"; v <- c(1, 2, 3); T <- FALSE
es <- alist(
  a > 10 & ab < 5, ab > a, a == ab * 10, `if` > 2, `a b` == "x", `a b` %in% c("x", "A"), nchar(`a b`) == 1, nchar(s) == 3,
  a %in% v, a %in% (v * 10), a / 10 == x, a > x, a == a_local * 2, (a) > 10, ((a > 10)), !(!(a > 10)), !a > 10, -a < -50, a > -1,
  b, !b, b & a > 10, b | is.na(b), b == TRUE, b == T, b %in% c(TRUE, NA), is.na(b), xor(b, a > 20), isTRUE(b), b == 1, b > 0, b == "TRUE",
  startsWith(s, "a"), grepl("^a", s), grepl("a", s, fixed = TRUE), grepl(s2, s), grepl(pattern = "b+", x = s), grepl(s, "abbb"), substr(s, 1, 1) == "a", toupper(s) == "BBB",
  s > "a", s >= "Z", s < "é", s == "é", s %in% c("a", NA), !(s %in% c("a", NA)), s != "a", is.na(s) | s == "z", s == 1, s < 5,
  f64 > 0, f64 == 0.1, f64 == 0.3, f64 >= 0.30000000000000004, is.nan(f64), is.na(f64), !is.na(f64), is.finite(f64), f64 != 0.1, f64 %in% c(NaN), f64 %in% c(NA), f64 %in% c(0.1, NaN), !(f64 %in% 0.1), f64 == -0, f64 < Inf, f64 <= Inf, f64 > -Inf,
  f32 == 0.1, f32 > 0.1, f32 >= 0.1, f32 == 0.10000000149011612, f32 %in% c(0.10000000149011612, 1.5), f32 < 1e-44, f32 == 16777216, f32 > 16777216, is.na(f32), f32 != 1.5,
  d == "2024-01-31", d > "2024-01-31", d == as.Date("2024-01-31"), d > 19000, d %in% as.Date(c("2024-01-31", "2024-02-29")), d == "2024-1-31", d < "0001-01-02", d >= "9999-12-31", d == 19753L,
  d == as.POSIXct("2024-01-31", tz = "UTC"), ts == as.Date("2024-01-31"), d == "2024-02-30", d == "2024-01-31 00:00:00", d == "",
  ts == "2024-01-31 12:00:00.123456", ts > "2024-06-15 12:00:00.5", ts >= "2024-06-15T12:00:00.999999Z", ts == "2024-06-15 12:00:00.999999", ts == "1969-12-31 23:59:59.999999",
  ts == as.POSIXct("2024-03-10 10:00:00", tz = "UTC"), ts == as.POSIXct("2024-03-10 23:45:00", tz = "Pacific/Chatham"), ts < "1970-01-01 00:00:00.000002", ts == "1970-01-01 00:00:00.000001",
  ts == "2024-03-10 12:00:00+02:00", ts == "2024-03-10 12:00:00+0200", ts == "2024-03-10", ts > "2024-03-10", tn == "2024-03-10 10:00:00.000001", tn == "2024-03-10 10:00:00.000001Z", tn > "1900-01-01 00:00:00", tn == as.POSIXct("2024-03-10 02:30:00", tz = "UTC"),
  ts %in% as.POSIXct(c("2024-03-10 10:00:00", NA), tz = "UTC"), ts > 1.7e9, ts == 1710064800,
  dec == 12.3, dec == "12.30", dec == "12.3", dec > 0.1, dec >= 0.1, dec == 0.1, dec %in% c(0.1, 1), dec < -99999999.98, dec == 99999999.99, dec == -0.01, dec != 0, dec == "1e2", dec == "0.100",
  dec15 == 1234567890.12345, dec15 == "1234567890.12345", dec15 == 0.3, dec15 == 0.30001, dec15 == 1e-5, dec15 == "0.00001", dec15 >= 9999999999.99999, dec15 == 1e5, dec15 > 99999,
  i8 == 127L, i8 > 126.5, i8 < -127.5, i16 %in% c(32767, -32768), i32 == 2147483647, i32 == -2147483647, i32 > 2147483646, i32 %in% NA, is.na(i32), i32 == "2147483647", i32 == 2147483647.5,
  a > 10 | stop("boom"), a %in% numeric(), a %in% NULL, a == numeric(), a == c(10, 20), a == NULL, a == list(10), a == quote(x), a == factor("10"), a %in% factor(c("10", "20")),
  a %in% c(x = 10, x = 20), s %in% c(a = "a"), a == c(n = 10), a + c(n = 0) == 10,
  abs(f64) > 0.2, round(f64) == 0, sqrt(a) > 5, a %% 20 == 0, a %/% 20 == 2, log(a) > 4, exp(a) > 1, a^2 > 1000, as.character(a) == "10", as.numeric(s) > 0, as.integer(f64) == 0L,
  max(a) == a, a[1] == 10, rev(a) > 10, cumsum(a) > 50, ifelse(a > 10, TRUE, FALSE), a > mean(v), a > mean(a), a == a, a != a, is.na(a + NA), a > NA, TRUE, FALSE, NA, a > 10 & TRUE, a > 10 | NA, a > 10 & NA,
  base::nchar(s) == 1, nchar(s, "bytes") == 2, nchar(s, type = "bytes") == 2, a > 10 && ab > 1, if (TRUE) a > 10, (function(z) z > 10)(a), a |> (\(z) z > 10)(), identity(a > 10), `>`(a, 10), a > 10L, a > "10", a > 1e1, a == 1e1L,
  substr(s, 1, v) == "a", substr(s, a, a) == "a", startsWith("abc", s), endsWith(s, s), nchar(s) == nchar(`a b`), s == `a b`, s > `a b`, tolower(s) == s, is.na(s) == is.na(d)
)
for (e in es) chk(e)

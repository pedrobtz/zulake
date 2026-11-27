source(file.path(Sys.getenv("W"), "common.R"))
tbl <- lake_open(file.path(W, "t/types"))
sh <- function(label, e) { r <- try1(e); cat(sprintf("%-46s ", label)); if (is_err(r)) cat("ERR[", sub("zulake_error_", "", r$cls), "]", substr(r$msg, 1, 120), "\n") else if (is.data.frame(r)) cat("df", nrow(r), "x", ncol(r), ":", paste(names(r), collapse = ","), "\n") else cat(paste(utils::capture.output(str(r))[1], collapse = ""), "\n") }
lat <- "\xe9"; Encoding(lat) <- "latin1"
cv <- list(`c("a","ab")` = c("a", "ab"), `"ab"` = "ab", `"a b"` = "a b", `"if"` = "if", dup = c("a", "a"), `named dup` = c(x = "a", x = "ab"), factor = factor(c("ab", "a")), int = 1L, dbl = 2, lgl = TRUE, `NA` = NA, NAc = NA_character_, zero = character(), list = list("a"), empty = "", `"A"` = "A", partial = "de", nl = "a\nb", lat = lat, `c(a,NA)` = c("a", NA), sym = quote(a), btick = "`a`", ws = " a", all_rev = rev(lake_schema(tbl)$name))
for (n in names(cv)) sh(paste("columns =", n), lake_read(tbl, columns = cv[[n]]))
sh("filter col not in columns", lake_read(tbl, columns = "a", filter = ab > 10))
sh("filter col not in columns s", lake_read(tbl, columns = c("ab"), filter = s == "a" & a == 10))
r1 <- lake_read(tbl, columns = c("ab", "a"), filter = a > 50); r2 <- suppressWarnings(lake_read(tbl, filter = a > 50))[, c("ab", "a")]; cat("columns+filter same as subset:", same_df(r1, r2), "\n")

# zero-column / zero-row
sh("filter FALSE", lake_read(tbl, columns = "a", filter = FALSE)); z <- lake_read(tbl, columns = c("a", "s", "d", "ts", "f64", "b"), filter = a > 1e6); str(z)
z0 <- lake_read(tbl, columns = c("a", "s", "d", "ts", "f64", "b")); cat("zero-row classes equal:", identical(lapply(z, class), lapply(z0, class)), identical(attributes(z$ts), attributes(z0$ts)), "\n")
zi <- suppressWarnings(lake_read(tbl, columns = "i64", int64 = "integer64", filter = a > 1e6)); cat("zero-row i64 class:", class(zi$i64), "\n")
# int64 arg matrix
for (v in list("double", "integer64", "int", c("double", "integer64"), c("integer64", "double"), NULL, NA, 1, TRUE, "d", "", factor("integer64"), character(), "Double")) sh(paste("int64 =", paste(format(v), collapse = ",")), class(suppressWarnings(lake_read(tbl, columns = "i64", int64 = v))$i64))
# lake_walk
n <- 0; ids <- list(); r <- suppressWarnings(lake_walk(tbl, function(p) { n <<- n + nrow(p); ids[[length(ids) + 1]] <<- p$a }, filter = a > 50)); cat("walk returns NULL:", is.null(r), " rows:", n, " pieces:", length(ids), "\n")
cat("walk == read:", identical(unlist(ids), lake_read(tbl, columns = "a", filter = a > 50)$a), "\n")
for (f in list(NULL, "identity", 1, quote(identity), function() 1, function(x, y) 1, print)) sh(paste("walk FUN", class(f)[1]), suppressWarnings(lake_walk(tbl, f, columns = "a", filter = a > 110)))
sh("walk no FUN", lake_walk(tbl))
k <- 0; sh("walk skips empty pieces", { suppressWarnings(lake_walk(tbl, function(p) k <<- k + 1, filter = a == 10 | a == 120)); k })
sh("walk FUN error", suppressWarnings(lake_walk(tbl, function(p) stop("mine"))))
# count
cat("count:", lake_count(tbl), "nrow:", nrow(suppressWarnings(lake_read(tbl))), "\n")
for (v in list(NA, 1, "TRUE", NULL, c(TRUE, FALSE), logical())) sh(paste("count footers", format(v)[1]), lake_count(tbl, footers = v))
ns <- lake_open(file.path(W, "t/types_nostats")); sh("count nostats", lake_count(ns)); sh("count nostats footers", lake_count(ns, footers = TRUE))
for (v in list(NA, 1, "TRUE", NULL, c(TRUE, FALSE))) sh(paste("files stats", format(v)[1]), suppressWarnings(lake_files(tbl, stats = v)))
sh("files stats=FALSE names", names(lake_files(tbl, stats = FALSE))); sh("files names", names(suppressWarnings(lake_files(tbl))))
sh("non-table", lake_files(list())); sh("non-table read", lake_read("x")); sh("is_table num", lake_is_table(1)); sh("is_table NA", lake_is_table(NA_character_)); sh("is_table c()", lake_is_table(c("a", "b"))); sh("is_table ''", lake_is_table("")); sh("is_table file", lake_is_table(file.path(W, "common.R"))); sh("open file", lake_open(file.path(W, "common.R"))); sh("open ~", lake_is_table("~")); sh("open trailing /", lake_version(lake_open(paste0(file.path(W, "t/types"), "/")))); sh("open file://", lake_version(lake_open(paste0("file://", file.path(W, "t/types"))))); sh("open factor", lake_open(factor(file.path(W, "t/types"))))
sh("open relative", { old <- setwd(file.path(W, "t")); on.exit(setwd(old)); t3 <- lake_open("types"); setwd(old); nrow(suppressWarnings(lake_read(t3))) })

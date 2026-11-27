source("setup.R")
d <- file.path(getwd(), "azurite")
Sys.setenv(ZULAKE_AZURITE_ENDPOINT = "https://127.0.0.1:10000/devstoreaccount1", ZULAKE_AZURITE_CA = file.path(d, "ca.pem"))
ep <- azurite_endpoint(); cl <- azurite_client()
src <- file.path(fixture_dir(), "tables")
tabs <- c("zl-basic", "zl-partitioned", "zl-checkpoint", "table-with-dv-small", "zl-orders", "zl-multipart-checkpoint", "v2-classic-checkpoint-json", "zl-log-compaction")
if (!file.exists("azurite/uploaded")) {
  for (n in tabs) azurite_upload(file.path(src, n), "fixtures", n, ep, cl)
  # a table under a name with XML-special and URL-special characters
  azurite_upload(file.path(src, "zl-basic"), "fixtures", "we&ird <t>'\"b+l%41 é#?", ep, cl)
  # zl-basic plus HNS-style directory markers and junk in _delta_log
  azurite_upload(file.path(src, "zl-basic"), "fixtures", "hns", ep, cl)
  h <- c(Authorization = paste("Bearer", azurite_token), `x-ms-version` = "2023-11-03", `x-ms-blob-type` = "BlockBlob")
  put <- function(name, body = raw(), extra = NULL) zuhttp::zu_resp_status(zuhttp::zu_put(paste0(ep, "/fixtures/", blob_url_path(name)), headers = c(h, extra), body = body, client = cl))
  print(put("hns/_delta_log", extra = c(`x-ms-meta-hdi_isfolder` = "true")))
  print(put("hns", extra = c(`x-ms-meta-hdi_isfolder` = "true")))
  print(put("hns/_delta_log/00000000000000000005.json", extra = c(`x-ms-meta-hdi_isfolder` = "true")))  # a "directory" named like a commit
  print(put("hns/_delta_log/_commits", extra = c(`x-ms-meta-hdi_isfolder` = "true")))
  print(put("hns/_delta_log/sub/00000000000000000006.json", charToRaw("{}\n")))
  writeLines("x", "azurite/uploaded")
}
options(zulake.azure_endpoint = ep, zulake.azure_client = cl)
tok <- function() azurite_token
cmp <- function(n, remote = n) {
  l <- lake_open(file.path(src, n))
  for (form in c("abfss", "dfs", "blob")) {
    r <- try_(lake_open(azurite_uri(remote, form), credentials = tok))
    if (inherits(r, "condition")) { cat(n, form, ":", class(r)[1], conditionMessage(r), "\n"); next }
    a <- suppressWarnings(try_(lake_read(r))); b <- suppressWarnings(lake_read(l))
    fa <- suppressWarnings(lake_files(r)); fb <- suppressWarnings(lake_files(l)); fa$uri <- fb$uri <- NULL
    cat(sprintf("%-28s %-5s v%s read:%s files:%s history:%s\n", n, form, lake_version(r), identical(a, b), identical(fa, fb), identical(lake_history(r)$version, lake_history(l)$version)))
  }
}
for (n in tabs) cmp(n)
cat("== weird name\n")
enc <- zulake:::url_encode("we&ird <t>'\"b+l%41 é#?")
r <- try_(lake_open(paste0("abfss://fixtures@devstoreaccount1.dfs.core.windows.net/", enc), credentials = tok)); if (inherits(r, "condition")) show(r) else cat("opened v", lake_version(r), "read same:", identical(lake_read(r), lake_read(lake_open(file.path(src, "zl-basic")))), "\n")
cat("== hns markers\n")
r <- try_(lake_open(azurite_uri("hns"), credentials = tok)); if (inherits(r, "condition")) show(r) else { cat("opened v", lake_version(r), "read same:", identical(lake_read(r), lake_read(lake_open(file.path(src, "zl-basic")))), "\n"); print(lake_log(r)[, 1:3]) }
print(try_(lake_is_table(azurite_uri("hns/_delta_log"), credentials = tok)))
st <- zulake:::storage_for(azurite_uri("hns"), tok)
print(st$head("_delta_log")); print(try_(st$get("_delta_log"))); print(st$list("_delta_log/")$name); print(st$list("")$name)
cat("== auth\n")
for (case in list(list("expired", function() azurite_token_expired), list("wrong aud", function() azurite_token_wrong_audience), list("garbage", function() "abc.def.ghi"), list("anonymous", NULL),
                  list("expired then good", local({k <- 0; function() { k <<- k + 1; if (k == 1) azurite_token_expired else azurite_token }})))) {
  r <- try_(lake_open(azurite_uri("zl-basic"), credentials = case[[2]]))
  cat(case[[1]], ":", if (inherits(r, "condition")) paste(class(r)[1], conditionMessage(r), "| leak:", has_token(r, azurite_token_expired) || has_token(r, azurite_token_wrong_audience)) else "opened", "\n")
}
cat("== missing container / missing table / is_table\n")
print(try_(lake_is_table("abfss://nocontainer@devstoreaccount1.dfs.core.windows.net/t", credentials = tok)))
print(try_(lake_is_table(azurite_uri("nope"), credentials = tok)))
print(try_(lake_open("abfss://nocontainer@devstoreaccount1.dfs.core.windows.net/t", credentials = tok)))
print(try_(lake_is_table("abfss://fixtures@devstoreaccount1.dfs.core.windows.net/", credentials = tok)))
cat("== ranges on Azurite\n")
st <- zulake:::storage_for(azurite_uri("table-with-dv-small"), tok); f <- "deletion_vector_61d16c75-6994-46b7-a15b-8b538852e50e.bin"
b <- st$get(f); for (a in list(c(0,0), c(44,44), c(0,44), c(0,45), c(45,45), c(45,50), c(44,100))) { r <- try_(st$get_range(f, a[1], a[2])); cat(a, "->", if (is.raw(r)) paste("ok", identical(r, b[(a[1]+1):(a[2]+1)])) else conditionMessage(r), "\n") }
print(st$head(f)); print(st$head("nope")); print(try_(st$get("nope")))

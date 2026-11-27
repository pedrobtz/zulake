#' @keywords internal
"_PACKAGE"

## usethis namespace: start
## usethis namespace: end

## mockable bindings: start
## mockable bindings: end
NULL

# The credential registry's environments (azure.R) are made here, at load
# time, and not when the package is built: an environment made at build
# time is stored in the lazy-load database, and the loader's own
# environments keep a reference to it, which a srcref or a byte-code
# constant in a snapshot can reach (seen with the source kept, Stage 6).
.onLoad <- function(libname, pkgname) {
  ns <- topenv()
  assign("credential_env", new.env(parent = emptyenv()), envir = ns)
  assign("credential_state", new.env(parent = emptyenv()), envir = ns)
}

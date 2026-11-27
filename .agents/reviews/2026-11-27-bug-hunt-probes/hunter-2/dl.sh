#!/bin/sh
# usage: dl.sh <table>[@version] ... -- deltalake only
H=/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/hunt-2
A=""; for x in "$@"; do A="$A $H/t/$x"; done
(cd /Users/pbtz/src/github.com/pedrobtz/zulake/tools/oracle && uv run --frozen python $H/d.py $A 2>&1 | grep -v VIRTUAL_ENV; true)

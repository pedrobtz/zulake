#!/bin/sh
# usage: py.sh script.py args -- run a builder script in the oracle env
H=/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zulake/99132c85-5c9b-47ee-a548-13638a8ffee0/scratchpad/hunt/hunt-2
S=$H/$1; shift
(cd /Users/pbtz/src/github.com/pedrobtz/zulake/tools/oracle && PYTHONPATH=$H uv run --frozen python $S "$@" 2>&1 | grep -v VIRTUAL_ENV; true)

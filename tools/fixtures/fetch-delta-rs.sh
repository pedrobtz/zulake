#!/bin/sh
# Copies the delta-rs test tables zulake ships, byte for byte, from the pinned
# delta-rs commit into tests/testthat/fixtures/tables/.
#
#   sh tools/fixtures/fetch-delta-rs.sh
#
# delta-rs is Apache-2.0 (its root LICENSE.txt, copied to tests/testthat/fixtures/ as
# LICENSE-delta-rs.txt). The list is the one in PROVENANCE.md; change both
# together. COVID-19_NYT is New York Times data under its own terms and is
# never copied.
set -eu

COMMIT=40439ad6d37a9e99add5bd80796aa6179ebe339f
TABLES="
checkpoint-v2-table
column_mapping
deletion_vectors
delta-0.8.0-null-partition
delta-0.8.0-partitioned
delta-2.2.0-partitioned-types
simple_table
simple_table_with_checkpoint
table-with-dv-small
table_failed_last_checkpoint_update
table_with_column_mapping
table_with_edge_timestamps
table_with_ict
v2-classic-checkpoint-json
"

root=$(cd "$(dirname "$0")/../.." && pwd)
dest="$root/tests/testthat/fixtures/tables"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git -C "$work" init -q
git -C "$work" remote add origin https://github.com/delta-io/delta-rs.git
git -C "$work" sparse-checkout set crates/test/tests/data LICENSE.txt
git -C "$work" fetch -q --depth 1 --filter=blob:none origin "$COMMIT"
git -C "$work" checkout -q FETCH_HEAD

mkdir -p "$dest"
cp "$work/LICENSE.txt" "$dest/../LICENSE-delta-rs.txt"
for t in $TABLES; do
  rm -rf "${dest:?}/$t"
  cp -R "$work/crates/test/tests/data/$t" "$dest/$t"
done
echo "copied $(echo $TABLES | wc -w | tr -d ' ') tables from delta-rs $COMMIT"

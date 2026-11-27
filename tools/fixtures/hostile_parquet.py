"""Hostile logs that need a Parquet writer: a checkpoint broken in one way.

    Rscript tools/fixtures/hostile.R                                # first
    (cd tools/oracle && uv run --frozen python ../fixtures/hostile_parquet.py)

hostile.R writes every other hostile log and empties
tests/testthat/fixtures/hostile/ first, so this runs after it and before
pack.py. pyarrow (the version tools/oracle/uv.lock pins) rewrites one
checkpoint of a copied fixture table; the same inputs give the same bytes,
so .github/workflows/oracle.yaml reruns it and fails on any diff. The
changes are listed in tests/testthat/fixtures/PROVENANCE.md; change both
together.
"""

import shutil
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests" / "testthat" / "fixtures"
TABLES = FIXTURES / "tables"
HOSTILE = FIXTURES / "hostile"


def copy_table(source, name):
    src = TABLES / source
    dest = HOSTILE / name
    assert src.is_dir(), src
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src, dest)
    return dest


def checkpoint_map_repeated_key():
    # The first add of zl-checkpoint-no-last's checkpoint at version 2 gets
    # a partitionValues MAP that holds the key "x" twice: a Parquet MAP is
    # a list of pairs, and nothing in Parquet stops a key repeating (#108).
    d = copy_table("zl-checkpoint-no-last", "checkpoint-map-repeated-key")
    f = d / "_delta_log" / "00000000000000000002.checkpoint.parquet"
    table = pq.read_table(f)
    adds = table.column("add").to_pylist()
    first = next(i for i, a in enumerate(adds) if a is not None)
    assert adds[first]["partitionValues"] == []
    adds[first]["partitionValues"] = [("x", "1"), ("x", "2")]
    j = table.schema.get_field_index("add")
    column = pa.array(adds, type=table.schema.field(j).type)
    table = table.set_column(j, table.schema.field(j), column)
    pq.write_table(table, f, compression="NONE")


def main():
    assert HOSTILE.is_dir(), "run tools/fixtures/hostile.R first"
    checkpoint_map_repeated_key()
    print("wrote 1 Parquet hostile fixture")


if __name__ == "__main__":
    main()

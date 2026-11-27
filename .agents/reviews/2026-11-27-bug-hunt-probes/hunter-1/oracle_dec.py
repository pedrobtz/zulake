import sys
from deltalake import DeltaTable
import pyarrow.compute as pc, pyarrow.dataset as ds
for p in sys.argv[1:]:
    try:
        dt = DeltaTable(p)
        t = dt.to_pyarrow_table(columns=["id", "pdec"])
        print(p.split("/")[-1], "all:", sorted(zip(t["id"].to_pylist(), [str(x) for x in t["pdec"].to_pylist()]))[:2])
        f = dt.to_pyarrow_table(columns=["id", "pdec"], filters=[("pdec", ">", __import__("decimal").Decimal("-1000"))])
        print("   pdec > -1000 ids:", sorted(f["id"].to_pylist()))
    except Exception as e:
        print(p.split("/")[-1], "ERR", str(e)[:200])

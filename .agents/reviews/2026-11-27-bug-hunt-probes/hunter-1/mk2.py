import sys, os, shutil, datetime as dt, decimal
import pyarrow as pa
from deltalake import write_deltalake, DeltaTable
out = sys.argv[1]
D = decimal.Decimal
schema = pa.schema([("id", pa.int32()),
 ("pl", pa.int64()), ("pdec", pa.decimal128(10,2)), ("pts", pa.timestamp("us", tz="UTC")), ("ptn", pa.timestamp("us")),
 ("pb", pa.bool_()), ("ps", pa.string()), ("pd", pa.date32()), ("pf", pa.float64()), ("pi", pa.int32()), ("pi8", pa.int8())])
def T(s): return dt.datetime.fromisoformat(s)
def TZ(s): return dt.datetime.fromisoformat(s).replace(tzinfo=dt.timezone.utc)
rows = dict(
 id=list(range(1,9)),
 pl=[1, 2**53-1, 2**53+1, 9223372036854775807, -9223372036854775808, None, 0, -5],
 pdec=[D("12.30"), D("-0.01"), D("0.00"), D("99999999.99"), None, D("0.10"), D("100.00"), D("1.00")],
 pts=[TZ("2024-01-31 12:00:00.123456"), TZ("1969-12-31 23:59:59.999999"), None, TZ("2024-03-10 10:00:00"), TZ("2024-11-03 05:30:00"), TZ("1970-01-01 00:00:00"), TZ("2024-06-15 12:00:00.5"), TZ("2262-01-01 00:00:00")],
 ptn=[T("2024-01-31 12:00:00.123456"), T("1969-12-31 23:59:59.999999"), None, T("2024-03-10 10:00:00"), T("2024-11-03 05:30:00"), T("1970-01-01 00:00:00"), T("2024-06-15 12:00:00.5"), T("1900-01-01 00:00:00")],
 pb=[True, False, None, True, False, True, False, True],
 ps=["a", "bbb", None, "é", "Z", "x\ny", "a b/c=d%", "\U0001F600"],
 pd=[dt.date(2024,1,31), dt.date(1969,12,31), None, dt.date(2024,2,29), dt.date(1,1,1), dt.date(9999,12,31), dt.date(1970,1,1), dt.date(2024,3,1)],
 pf=[0.1, 0.30000000000000004, None, float("inf"), float("nan"), -0.0, 1e300, 5e-324],
 pi=[1, 2147483647, -2147483648, None, 0, -1, 10, 100],
 pi8=[1, 127, -128, None, 0, -1, 10, 100],
)
if os.path.exists(out): shutil.rmtree(out)
for k in sys.argv[2:]:
    o = os.path.join(out, "by_" + k)
    try:
        write_deltalake(o, pa.table(rows, schema=schema), partition_by=[k])
        print(k, "ok", len(DeltaTable(o).file_uris()))
    except Exception as e:
        print(k, "FAIL", str(e)[:200])

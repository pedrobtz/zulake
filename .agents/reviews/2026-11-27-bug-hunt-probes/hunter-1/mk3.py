import sys, os, shutil, random, datetime as dt
import pyarrow as pa
from deltalake import write_deltalake
out = sys.argv[1]
random.seed(7)
lo = -62135596800_000000  # 0001-01-01
hi = 253402300799_999999  # 9999-12-31 23:59:59.999999
us = [lo, hi, 0, 1, -1, 999999, -999999, 1_000000, -1_000000, 2**53, -2**53, 1710064800_000000, 4102444800_000000-1]
us += [random.randint(lo, hi) for _ in range(120)]
us += [random.randint(-10**9, 10**9) for _ in range(40)]           # near epoch
us += [random.randint(1_600_000_000_000000, 1_800_000_000_000000) for _ in range(120)]
us += [None]
def txt(u):
    if u is None: return None
    d = dt.datetime(1,1,1) + dt.timedelta(microseconds=u - lo)
    return d.strftime("%Y-%m-%d %H:%M:%S.") + "%06d" % d.microsecond
days = [None if u is None else u // 86400_000000 for u in us]
t = pa.table({"id": pa.array(range(len(us)), pa.int32()), "us": pa.array(us, pa.int64()), "txt": pa.array([txt(u) for u in us]),
  "ts": pa.array(us, pa.timestamp("us", tz="UTC")), "tn": pa.array(us, pa.timestamp("us")), "d": pa.array(days, pa.date32())})
if os.path.exists(out): shutil.rmtree(out)
n = len(us)
for i in range(0, n, 50):
    write_deltalake(out, t.slice(i, 50), mode="append")

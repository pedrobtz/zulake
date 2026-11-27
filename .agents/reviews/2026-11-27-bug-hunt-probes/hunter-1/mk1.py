import sys, os, shutil, datetime as dt, decimal
import pyarrow as pa
from deltalake import write_deltalake, DeltaTable
out = sys.argv[1]
D = decimal.Decimal
schema = pa.schema([
 ("i8", pa.int8()), ("i16", pa.int16()), ("i32", pa.int32()), ("i64", pa.int64()),
 ("f32", pa.float32()), ("f64", pa.float64()), ("b", pa.bool_()),
 ("s", pa.string()), ("d", pa.date32()), ("ts", pa.timestamp("us", tz="UTC")),
 ("tn", pa.timestamp("us")), ("dec", pa.decimal128(10,2)), ("dec15", pa.decimal128(15,5)),
 ("ab", pa.int32()), ("a", pa.int32()), ("if", pa.int32()), ("a b", pa.string()),
])
def T(s): return dt.datetime.fromisoformat(s)
def TZ(s): return dt.datetime.fromisoformat(s).replace(tzinfo=dt.timezone.utc)
batches = [
 # file 1
 dict(i8=[1,2,None], i16=[100,-100,0], i32=[1,2,3], i64=[1, 2**53-1, -5],
      f32=[0.1,1.5,None], f64=[0.1,0.30000000000000004,1e300], b=[True,False,None],
      s=["a","bbb",None], d=[dt.date(2024,1,31),dt.date(1969,12,31),None],
      ts=[TZ("2024-01-31 12:00:00.123456"),TZ("1969-12-31 23:59:59.999999"),None],
      tn=[T("2024-03-10 02:30:00"),T("2024-01-01 00:00:00"),None],
      dec=[D("12.30"),D("-0.01"),None], dec15=[D("1234567890.12345"),D("0.00001"),D("-1.5")],
      ab=[1,2,3], a=[10,20,30], **{"if":[1,2,3], "a b":["x","y","z"]}),
 # file 2
 dict(i8=[127,-128,5], i16=[32767,-32768,7], i32=[2147483647,-2147483647,10], i64=[2**53, 2**53+1, 9223372036854775807],
      f32=[float("nan"),3.4028234e38,-1.5], f64=[float("nan"),float("inf"),-0.0], b=[True,True,True],
      s=["é","Z","z"], d=[dt.date(2024,2,29),dt.date(2024,3,1),dt.date(9999,12,31)],
      ts=[TZ("2024-03-10 10:00:00"),TZ("2024-11-03 05:30:00"),TZ("2262-01-01 00:00:00")],
      tn=[T("2024-03-10 10:00:00.000001"),T("2024-11-03 05:30:00"),T("1900-01-01 00:00:00")],
      dec=[D("99999999.99"),D("-99999999.99"),D("0.00")], dec15=[D("9999999999.99999"),D("0.10000"),D("100")],
      ab=[4,5,6], a=[40,50,60], **{"if":[4,5,6], "a b":["x\ny","été","\U0001F600"]}),
 # file 3: all nulls for some
 dict(i8=[None,None,None], i16=[None]*3, i32=[None]*3, i64=[None]*3,
      f32=[None]*3, f64=[None]*3, b=[None]*3, s=[None]*3, d=[None]*3, ts=[None]*3, tn=[None]*3,
      dec=[None]*3, dec15=[None]*3, ab=[7,8,9], a=[70,80,90], **{"if":[7,8,9], "a b":[None,"",  "a"]}),
 # file 4: strings long (truncation?), i64 negative extremes
 dict(i8=[0,0,0], i16=[0,0,0], i32=[0,0,0], i64=[-9223372036854775808, -2**53-1, 0],
      f32=[1e-45,0.0,16777217.0], f64=[5e-324,1.7976931348623157e308,123456789.123456789], b=[False,False,False],
      s=["a"*40+"z", "a"*40+"\U0001F600", "a"*40],
      d=[dt.date(1,1,1),dt.date(1970,1,1),dt.date(2024,12,31)],
      ts=[TZ("1970-01-01 00:00:00.000001"),TZ("2024-06-15 12:00:00.999999"),TZ("2024-06-15 12:00:00.5")],
      tn=[T("1970-01-01 00:00:00"),T("2024-06-15 12:00:00.999999"),T("2024-06-15 12:00:00.5")],
      dec=[D("0.10"),D("1.00"),D("100.00")], dec15=[D("0.3"),D("0.30001"),D("1e5")],
      ab=[10,11,12], a=[100,110,120], **{"if":[10,11,12], "a b":["A","b","C"]}),
]
if os.path.exists(out): shutil.rmtree(out)
for bt in batches:
    write_deltalake(out, pa.table(bt, schema=schema), mode="append")
print(DeltaTable(out).version())

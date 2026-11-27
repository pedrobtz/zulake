# column mapping and the read pipeline
from tk import *
from dvtk import *
import datetime, decimal
def pf(name, typ, phys, id=None):
    md = {"delta.columnMapping.physicalName": phys}
    if id is not None: md["delta.columnMapping.id"] = id
    return field(name, typ, md)
CM = proto(2, 5); CONF = {"delta.columnMapping.mode": "name", "delta.columnMapping.maxColumnId": "9"}
# m1: name mode, partition by physical key, a file lacking a column
d = new("m1"); F = [pf("id", "long", "c1", 1), pf("s", "string", "c2", 2), pf("p", "string", "c3", 3)]
commit(d, 0, [ci(), CM, meta(F, ["p"], CONF), data(d, "f0.parquet", {"c1": [1], "c2": ["x"]}, pv={"c3": "P0"}), data(d, "f1.parquet", {"c1": [2]}, pv={"c3": "P1"})])
# m2: rename trap: file also holds a column literally named like a logical name
d = new("m2"); F = [pf("id", "long", "c1", 1), pf("a", "string", "c2", 2)]
commit(d, 0, [ci(), CM, meta(F, [], CONF), data(d, "f0.parquet", {"c1": [1], "c2": ["right"], "a": ["wrong"], "id": [999]})])
# m3: partition values keyed by logical name under name mode
d = new("m3"); F = [pf("id", "long", "c1", 1), pf("p", "string", "c3", 3)]
commit(d, 0, [ci(), CM, meta(F, ["p"], CONF), data(d, "f0.parquet", {"c1": [1]}, pv={"p": "LOGICAL"})])
# m4: both keys present
d = new("m4"); commit(d, 0, [ci(), CM, meta(F, ["p"], CONF), data(d, "f0.parquet", {"c1": [1]}, pv={"p": "LOGICAL", "c3": "PHYSICAL"})])
# m5: mode variants
for nm, conf, p in [("m5_upper", {"delta.columnMapping.mode": "NAME"}, CM), ("m5_none", {"delta.columnMapping.mode": "none"}, CM), ("m5_id", {"delta.columnMapping.mode": "id"}, CM),
                    ("m5_r1", {"delta.columnMapping.mode": "name"}, proto(1, 2)), ("m5_r3nofeat", {"delta.columnMapping.mode": "name"}, proto(3, 7, [], ["columnMapping"])),
                    ("m5_r3", {"delta.columnMapping.mode": "name"}, proto(3, 7, ["columnMapping"], ["columnMapping"])), ("m5_empty", {"delta.columnMapping.mode": ""}, CM)]:
    d = new(nm); F = [pf("id", "long", "c1", 1), pf("a", "string", "c2", 2)]
    commit(d, 0, [ci(), p, meta(F, [], conf), data(d, "f0.parquet", {"c1": [1], "c2": ["phys"], "a": ["logical"], "id": [999]})])
# m6: two logical fields with one physical name
d = new("m6"); F = [pf("id", "long", "c1", 1), pf("a", "long", "c1", 2)]
commit(d, 0, [ci(), CM, meta(F, [], CONF), data(d, "f0.parquet", {"c1": [1]})])
# m7: metaData mid-log: drop column a and add a new a with a new physical name
d = new("m7"); F0 = [pf("id", "long", "c1", 1), pf("a", "string", "c2", 2)]; F1 = [pf("id", "long", "c1", 1), pf("a", "string", "c4", 4)]
commit(d, 0, [ci(), CM, meta(F0, [], CONF), data(d, "f0.parquet", {"c1": [1], "c2": ["old-a"]})])
commit(d, 1, [ci(), meta(F1, [], CONF), data(d, "f1.parquet", {"c1": [2], "c4": ["new-a"]})])
# m8: upgrade from none to name mid-log (physical = logical for old columns), then rename
d = new("m8"); commit(d, 0, [ci(), proto(1, 2), meta([field("id"), field("a", "string")]), data(d, "f0.parquet", {"id": [1], "a": ["v0"]})])
F1 = [pf("id", "long", "id", 1), pf("b", "string", "a", 2)]
commit(d, 1, [ci(), CM, meta(F1, [], CONF), data(d, "f1.parquet", {"id": [2], "a": ["v1"]})])
# dots in names
d = new("m9_dot"); commit(d, 0, [ci(), proto(), meta([field("id"), field("a.b", "long")]), data(d, "f0.parquet", {"id": [1], "a.b": [42]})])
st = pa.struct([("b", pa.int64())])
d = new("m9_dot2"); F = [field("id"), field("a", {"type": "struct", "fields": [field("b")]}), field("a.b", "long")]
commit(d, 0, [ci(), proto(), meta(F), data(d, "f0.parquet", pa.table({"id": [1], "a": pa.array([{"b": 7}], st), "a.b": [42]}))])
d = new("m9_case"); commit(d, 0, [ci(), proto(), meta([field("ID"), field("Val", "string")]), data(d, "f0.parquet", {"id": [1], "val": ["x"]})])
# ---- read pipeline: every type present in one file, absent in the other
cols = {"id": pa.array([1, 2], pa.int64()), "b": pa.array([1, None], pa.int8()), "sh": pa.array([2, None], pa.int16()), "i": pa.array([3, None], pa.int32()),
        "f": pa.array([1.5, None], pa.float32()), "dbl": pa.array([2.5, None], pa.float64()), "s": pa.array(["x", None]), "bin": pa.array([b"\x00\x01", None], pa.binary()),
        "bo": pa.array([True, None]), "dt": pa.array([datetime.date(2024, 1, 5), None]), "ts": pa.array([datetime.datetime(2024, 1, 5, 10, 0, 0, 123456), None], pa.timestamp("us", tz="UTC")),
        "ntz": pa.array([datetime.datetime(2024, 1, 5, 10), None], pa.timestamp("us")), "dec": pa.array([decimal.Decimal("1.50"), None], pa.decimal128(10, 2))}
types = {"id": "long", "b": "byte", "sh": "short", "i": "integer", "f": "float", "dbl": "double", "s": "string", "bin": "binary", "bo": "boolean", "dt": "date", "ts": "timestamp", "ntz": "timestamp_ntz", "dec": "decimal(10,2)"}
NTZ = proto(3, 7, ["timestampNtz"], ["timestampNtz"])
F = [field(k, v) for k, v in types.items()]
for nm, order in [("r_types_ab", ["a_full.parquet", "b_idonly.parquet"]), ("r_types_ba", ["a_idonly.parquet", "b_full.parquet"])]:
    d = new(nm); acts = [ci(), NTZ, meta(F)]
    for fn in order:
        acts.append(data(d, fn, pa.table(cols) if "full" in fn else pa.table({"id": pa.array([10], pa.int64())})))
    commit(d, 0, acts)
# r_only: no file has the columns at all
d = new("r_types_none"); commit(d, 0, [ci(), NTZ, meta(F), data(d, "a.parquet", pa.table({"id": pa.array([10], pa.int64())}))])
# r_empty: a zero-row file and a table of only zero-row files
d = new("r_zero"); commit(d, 0, [ci(), NTZ, meta(F), data(d, "a.parquet", pa.table(cols).slice(0, 0)), data(d, "b.parquet", pa.table(cols))])
d = new("r_zero_only"); commit(d, 0, [ci(), NTZ, meta(F), data(d, "a.parquet", pa.table(cols).slice(0, 0))])
# physical types that differ from the schema
d = new("r_int32_as_long"); commit(d, 0, [ci(), proto(), meta([field("id"), field("x", "long")]), data(d, "a.parquet", pa.table({"id": [1], "x": pa.array([5], pa.int32())})), data(d, "b.parquet", pa.table({"id": [2], "x": pa.array([6], pa.int64())}))])
d = new("r_int64_as_int"); commit(d, 0, [ci(), proto(), meta([field("id"), field("x", "integer")]), data(d, "a.parquet", pa.table({"id": [1], "x": pa.array([2**40], pa.int64())}))])
d = new("r_str_as_long"); commit(d, 0, [ci(), proto(), meta([field("id"), field("x", "long")]), data(d, "a.parquet", pa.table({"id": [1], "x": pa.array(["text"])}))])
d = new("r_ts_ms"); commit(d, 0, [ci(), proto(), meta([field("id"), field("x", "timestamp")]), data(d, "a.parquet", pa.table({"id": [1, 2], "x": pa.array([datetime.datetime(2024, 1, 5, 10, 0, 0, 123000), None], pa.timestamp("ms", tz="UTC"))}))])
d = new("r_ts_ns"); p = data(d, "a.parquet", pa.table({"id": [1]})); t = pa.table({"id": [1, 2], "x": pa.array([1704448800123456789, None], pa.timestamp("ns", tz="UTC"))}); pq.write_table(t, d + "/a.parquet", version="2.6"); p["add"]["size"] = os.path.getsize(d + "/a.parquet")
commit(d, 0, [ci(), proto(), meta([field("id"), field("x", "timestamp")]), p])
d = new("r_ts_int96"); p = data(d, "a.parquet", pa.table({"id": [1]})); t = pa.table({"id": [1, 2], "x": pa.array([datetime.datetime(2024, 1, 5, 10, 0, 0, 123456), None], pa.timestamp("us"))}); pq.write_table(t, d + "/a.parquet", use_deprecated_int96_timestamps=True); p["add"]["size"] = os.path.getsize(d + "/a.parquet")
commit(d, 0, [ci(), proto(), meta([field("id"), field("x", "timestamp")]), p])
d = new("r_ts_local"); commit(d, 0, [ci(), proto(), meta([field("id"), field("x", "timestamp")]), data(d, "a.parquet", pa.table({"id": [1], "x": pa.array([datetime.datetime(2024, 1, 5, 10)], pa.timestamp("us"))}))])
d = new("r_ntz_utc"); commit(d, 0, [ci(), NTZ, meta([field("id"), field("x", "timestamp_ntz")]), data(d, "a.parquet", pa.table({"id": [1], "x": pa.array([datetime.datetime(2024, 1, 5, 10)], pa.timestamp("us", tz="UTC"))}))])
d = new("r_ts_tz"); commit(d, 0, [ci(), proto(), meta([field("id"), field("x", "timestamp")]), data(d, "a.parquet", pa.table({"id": [1], "x": pa.array([datetime.datetime(2024, 1, 5, 10)], pa.timestamp("us", tz="America/New_York"))}))])
# extra column in the file; columns in another order
d = new("r_extra"); commit(d, 0, [ci(), proto(), meta([field("id"), field("s", "string")]), data(d, "a.parquet", pa.table({"zz": [0], "s": ["x"], "id": [1]}))])
# row groups + dv
d = new("r_rg"); a = data(d, "a.parquet", pa.table({"id": list(range(100))})); pq.write_table(pa.table({"id": list(range(100))}), d + "/a.parquet", row_group_size=7); a["add"]["size"] = os.path.getsize(d + "/a.parquet")
a["add"]["deletionVector"] = inline([0, 6, 7, 13, 14, 98, 99])
commit(d, 0, [ci(), proto(3, 7, ["deletionVectors"], ["deletionVectors"]), meta(), a])
# nested columns
lt = pa.list_(pa.int64()); mp = pa.map_(pa.string(), pa.int64())
F = [field("id"), field("st", {"type": "struct", "fields": [field("b")]}), field("ar", {"type": "array", "elementType": "long", "containsNull": True}), field("mp", {"type": "map", "keyType": "string", "valueType": "long", "valueContainsNull": True}), field("z", "string")]
d = new("r_nested"); commit(d, 0, [ci(), proto(), meta(F), data(d, "a.parquet", pa.table({"id": [1], "st": pa.array([{"b": 7}], st), "ar": pa.array([[1, 2]], lt), "mp": pa.array([[("k", 1)]], mp), "z": ["end"]}))])

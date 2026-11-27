# partition values by type, and column mapping
from tk import *
def ptab(name, typ, values, rf=None):
    d = new(name); acts = [ci(), proto() if rf is None else proto(3, 7, rf, rf), meta([field("id"), field("p", typ)], ["p"])]
    for i, v in enumerate(values):
        acts.append(data(d, "f%d.parquet" % i, {"id": [i]}, pv={"p": v}))
    commit(d, 0, acts)
ptab("pt_string", "string", ["", None, "a", " ", "__HIVE_DEFAULT_PARTITION__", "null", "é", "a/b", "a%20b"])
ptab("pt_int", "integer", ["1", "+1", "01", "-0", "2147483647", "-2147483648", None, ""])
ptab("pt_int_sp", "integer", [" 1"]); ptab("pt_int_over", "integer", ["2147483648"]); ptab("pt_int_frac", "integer", ["1.0"]); ptab("pt_int_e", "integer", ["1e3"])
ptab("pt_long", "long", ["9007199254740993", "-9223372036854775808", "5"])
ptab("pt_long_small", "long", ["9007199254740991", "-5", "+7", "007"])
ptab("pt_byte", "byte", ["127", "-128", "0"]); ptab("pt_byte_over", "byte", ["128"])
ptab("pt_short", "short", ["32767", "-32768"])
ptab("pt_bool", "boolean", ["true", "false", "TRUE", "False", None])
ptab("pt_bool_bad", "boolean", ["1"]); ptab("pt_bool_t", "boolean", ["t"])
ptab("pt_date", "date", ["2024-01-05", "2024-1-5", "1969-12-31", "0001-01-01", "9999-12-31"])
ptab("pt_date_bad", "date", ["2024-02-30"]); ptab("pt_date_time", "date", ["2024-01-05 00:00:00"]); ptab("pt_date_neg", "date", ["-0001-01-01"]); ptab("pt_date_5", "date", ["10000-01-01"])
ptab("pt_ts", "timestamp", ["2024-01-05 10:00:00", "2024-01-05 10:00:00.123456", "2024-01-05T10:00:00Z", "2024-01-05T10:00:00.123456Z", "2024-01-05 10:00:00.5", "1969-12-31 23:59:59.999999", "2024-01-05T10:00:00.000000+02:00"])
ptab("pt_ts_nano", "timestamp", ["2024-01-05 10:00:00.123456789"]); ptab("pt_ts_date", "timestamp", ["2024-01-05"]); ptab("pt_ts_noZ", "timestamp", ["2024-01-05T10:00:00"]); ptab("pt_ts_60", "timestamp", ["2024-01-05 10:00:60"]); ptab("pt_ts_h1", "timestamp", ["2024-01-05 1:00:00"])
ptab("pt_ntz", "timestamp_ntz", ["2024-01-05 10:00:00", "2024-01-05 10:00:00.123456", "2024-01-05T10:00:00"], rf=["timestampNtz"])
ptab("pt_ntz_z", "timestamp_ntz", ["2024-01-05T10:00:00Z"], rf=["timestampNtz"])
ptab("pt_double", "double", ["1.5", "1e3", "-0.0", "NaN", "Infinity", "-Infinity", "1", ".5", "5.", "1E-2", "0.1"])
ptab("pt_double_inf", "double", ["inf"]); ptab("pt_double_nan", "double", ["nan"]); ptab("pt_double_hex", "double", ["0x10"]); ptab("pt_double_d", "double", ["1.5d"]); ptab("pt_double_big", "double", ["1e400"])
ptab("pt_float", "float", ["1.1", "16777217", "3.4028235e38", "1e39"])
ptab("pt_dec", "decimal(10,2)", ["1.50", "-0.01", "12345678.90", "1", "1.5"])
ptab("pt_dec_over", "decimal(4,2)", ["123.456"]); ptab("pt_dec_e", "decimal(10,2)", ["1e2"])
ptab("pt_bin", "binary", ["abc", "\u0001\u0002", ""])
# missing key / extra key / wrong case
d = new("pk_missing"); commit(d, 0, [ci(), proto(), meta([field("id"), field("p", "string")], ["p"]), data(d, "f0.parquet", {"id": [1]}, pv={}), data(d, "f1.parquet", {"id": [2]}, pv={"p": "a", "zz": "x"}), data(d, "f2.parquet", {"id": [3]}, pv={"P": "b"})])
d = new("pk_nokey"); a = data(d, "f0.parquet", {"id": [1]}); del a["add"]["partitionValues"]; commit(d, 0, [ci(), proto(), meta([field("id"), field("p", "string")], ["p"]), a])
# partition column also in the data file with another value
d = new("pk_infile"); commit(d, 0, [ci(), proto(), meta([field("id"), field("p", "string")], ["p"]), data(d, "f0.parquet", {"id": [1], "p": ["infile"]}, pv={"p": "inlog"})])
# partition columns in another order than the schema; partition col first in schema
d = new("pk_order"); commit(d, 0, [ci(), proto(), meta([field("b", "string"), field("id"), field("a", "string")], ["a", "b"]), data(d, "f0.parquet", {"id": [1]}, pv={"a": "A", "b": "B"})])
# partition column not in schema / listed twice / nested type
d = new("pk_noschema"); commit(d, 0, [ci(), proto(), meta([field("id")], ["p"]), data(d, "f0.parquet", {"id": [1]}, pv={"p": "a"})])
d = new("pk_twice"); commit(d, 0, [ci(), proto(), meta([field("id"), field("p", "string")], ["p", "p"]), data(d, "f0.parquet", {"id": [1]}, pv={"p": "a"})])
d = new("pk_case"); commit(d, 0, [ci(), proto(), meta([field("id"), field("P", "string")], ["p"]), data(d, "f0.parquet", {"id": [1]}, pv={"p": "a"})])
# metaData changes partition columns mid-log: p was data, becomes partition
d = new("pk_change"); commit(d, 0, [ci(), proto(), meta([field("id"), field("p", "string")], []), data(d, "f0.parquet", {"id": [1], "p": ["old"]})])
commit(d, 1, [ci(), meta([field("id"), field("p", "string")], ["p"]), data(d, "f1.parquet", {"id": [2]}, pv={"p": "new"})])
# and the reverse: p was partition, becomes data
d = new("pk_change2"); commit(d, 0, [ci(), proto(), meta([field("id"), field("p", "string")], ["p"]), data(d, "f0.parquet", {"id": [1]}, pv={"p": "old"})])
commit(d, 1, [ci(), meta([field("id"), field("p", "string")], []), data(d, "f1.parquet", {"id": [2], "p": ["new"]})])

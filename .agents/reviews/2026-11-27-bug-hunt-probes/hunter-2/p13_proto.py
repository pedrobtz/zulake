# protocol and metaData shapes
from tk import *
def t(name, p, m=None, cols=None):
    d = new(name); commit(d, 0, [ci(), p, m or meta(), data(d, "f0.parquet", cols or {"id": [1]})]); return d
P = lambda **k: {"protocol": k}
t("g_r0", P(minReaderVersion=0, minWriterVersion=2)); t("g_r4", P(minReaderVersion=4, minWriterVersion=7)); t("g_rneg", P(minReaderVersion=-1, minWriterVersion=2))
t("g_rstr", P(minReaderVersion="1", minWriterVersion=2)); t("g_rfrac", '{"protocol":{"minReaderVersion":1.5,"minWriterVersion":2}}'); t("g_r10", '{"protocol":{"minReaderVersion":1.0,"minWriterVersion":2}}')
t("g_r3_nofeat", P(minReaderVersion=3, minWriterVersion=7)); t("g_r3_null", P(minReaderVersion=3, minWriterVersion=7, readerFeatures=None, writerFeatures=None))
t("g_r3_empty", P(minReaderVersion=3, minWriterVersion=7, readerFeatures=[], writerFeatures=[]))
t("g_r2_feat", P(minReaderVersion=2, minWriterVersion=5, readerFeatures=["typeWidening"], writerFeatures=["typeWidening"]))
t("g_r1_feat", P(minReaderVersion=1, minWriterVersion=7, readerFeatures=["deletionVectors"], writerFeatures=["deletionVectors"]))
t("g_r3_dup", P(minReaderVersion=3, minWriterVersion=7, readerFeatures=["timestampNtz", "timestampNtz"], writerFeatures=["timestampNtz"]))
t("g_r3_case", P(minReaderVersion=3, minWriterVersion=7, readerFeatures=["DeletionVectors"], writerFeatures=["DeletionVectors"]))
t("g_r3_str", P(minReaderVersion=3, minWriterVersion=7, readerFeatures="deletionVectors", writerFeatures=[]))
t("g_r3_num", P(minReaderVersion=3, minWriterVersion=7, readerFeatures=[1], writerFeatures=[]))
t("g_r3_wonly", P(minReaderVersion=3, minWriterVersion=7, readerFeatures=[], writerFeatures=["typeWidening", "variantType"]))
t("g_w_only_r1", P(minReaderVersion=1, minWriterVersion=7, writerFeatures=["rowTracking", "zzz"]))
t("g_nowriter", P(minReaderVersion=1))
def M(**k):
    m = meta()["metaData"]; m.update(k); return {"metaData": m}
t("g_orc", proto(), M(format={"provider": "orc", "options": {}})); t("g_nofmt", proto(), {"metaData": {k: v for k, v in meta()["metaData"].items() if k != "format"}})
t("g_fmtopt", proto(), M(format={"provider": "parquet", "options": {"compression": "x"}}))
t("g_nopc", proto(), {"metaData": {k: v for k, v in meta()["metaData"].items() if k != "partitionColumns"}})
t("g_noconf", proto(), {"metaData": {k: v for k, v in meta()["metaData"].items() if k != "configuration"}})
t("g_confnum", proto(), M(configuration={"k": 1}))
def S(fields, **k): return M(schemaString=json.dumps({"type": "struct", "fields": fields}), **k)
t("g_s_empty", proto(), S([])); t("g_s_dup", proto(), S([field("id"), field("id")])); t("g_s_dupcase", proto(), S([field("id"), field("ID")]))
t("g_s_noname", proto(), S([{"type": "long", "nullable": True, "metadata": {}}])); t("g_s_notype", proto(), S([{"name": "id", "nullable": True, "metadata": {}}]))
t("g_s_unknown", proto(), S([field("id"), field("x", "varchar(10)")]), cols={"id": [1], "x": ["abc"]})
t("g_s_void", proto(), S([field("id"), field("x", "void")]), cols={"id": [1], "x": pa.array([None], pa.null())})
t("g_s_variant", proto(), S([field("id"), field("x", "variant")]), cols={"id": [1], "x": ["abc"]})
t("g_s_interval", proto(), S([field("id"), field("x", "interval day to second")]), cols={"id": [1], "x": [5]})
t("g_s_upper", proto(), S([field("id"), field("x", "STRING")]), cols={"id": [1], "x": ["abc"]})
t("g_s_dec0", proto(), S([field("id"), field("x", "decimal(5, 2)")]), cols={"id": [1], "x": pa.array([__import__("decimal").Decimal("1.50")], pa.decimal128(5, 2))})
t("g_s_dec", proto(), S([field("id"), field("x", "decimal")]), cols={"id": [1], "x": pa.array([__import__("decimal").Decimal("15")], pa.decimal128(10, 0))})
t("g_s_emptyname", proto(), S([field("id"), field("", "string")]), cols={"id": [1], "": ["abc"]})
t("g_s_notnull", proto(), S([{"name": "id", "type": "long", "nullable": False, "metadata": {}}]), cols={"id": pa.array([1, None], pa.int64())})
t("g_s_arr", proto(), M(schemaString='[{"name":"id","type":"long"}]')); t("g_s_typearr", proto(), M(schemaString='{"type":"array","elementType":"long","containsNull":true}'))
# metaData id changes mid-log; two metaData in different commits; protocol downgrade
d = t("g_idchange", proto()); commit(d, 1, [ci(), meta(id="other"), data(d, "f1.parquet", {"id": [2]})])
d = t("g_downgrade", proto(3, 7, ["typeWidening"], ["typeWidening"])); commit(d, 1, [ci(), proto(1, 2)])

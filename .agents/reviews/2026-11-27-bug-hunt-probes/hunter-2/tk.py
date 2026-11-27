# toolkit: hand-built Delta tables
import json, os, shutil, sys
import pyarrow as pa, pyarrow.parquet as pq
ROOT = os.path.dirname(os.path.abspath(__file__)) + "/t"
def new(name):
    d = os.path.join(ROOT, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d + "/_delta_log")
    return d
def proto(r=1, w=2, rf=None, wf=None):
    p = {"minReaderVersion": r, "minWriterVersion": w}
    if rf is not None: p["readerFeatures"] = rf
    if wf is not None: p["writerFeatures"] = wf
    return {"protocol": p}
def field(name, typ="long", md=None):
    return {"name": name, "type": typ, "nullable": True, "metadata": md or {}}
def meta(fields=None, part=(), conf=None, id="tid"):
    fields = fields or [field("id")]
    return {"metaData": {"id": id, "format": {"provider": "parquet", "options": {}},
            "schemaString": json.dumps({"type": "struct", "fields": fields}),
            "partitionColumns": list(part), "configuration": conf or {}, "createdTime": 1}}
def data(d, name, cols, pv=None, stats=True, **kw):
    t = cols if isinstance(cols, pa.Table) else pa.table(cols)
    p = os.path.join(d, name)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    pq.write_table(t, p)
    a = {"path": name, "partitionValues": pv or {}, "size": os.path.getsize(p),
         "modificationTime": 1000, "dataChange": True}
    if stats: a["stats"] = json.dumps({"numRecords": t.num_rows})
    a.update(kw)
    return {"add": a}
def rm(path, **kw):
    r = {"path": path, "dataChange": True, "deletionTimestamp": 2000}
    r.update(kw)
    return {"remove": r}
def cname(v): return "%020d.json" % v
def commit(d, v, actions, name=None, raw=None):
    p = os.path.join(d, "_delta_log", name or cname(v))
    with open(p, "w") as f:
        if raw is not None: f.write(raw)
        else:
            for a in actions: f.write((a if isinstance(a, str) else json.dumps(a)) + "\n")
    return p
def ci(ts=None, **kw):
    c = {"timestamp": 1, "operation": "WRITE"}
    if ts is not None: c["inCommitTimestamp"] = ts
    c.update(kw)
    return {"commitInfo": c}

# ---- checkpoints by hand
def _nullable(t):
    if pa.types.is_struct(t): return pa.struct([pa.field(f.name, _nullable(f.type), True) for f in t])
    if pa.types.is_map(t): return pa.map_(t.key_type, _nullable(t.item_type))
    if pa.types.is_list(t): return pa.list_(_nullable(t.value_type))
    return t
def cp_schema():
    s = pq.read_schema(os.path.dirname(os.path.abspath(__file__)) + "/ref_cp.parquet")
    return pa.schema([pa.field(f.name, _nullable(f.type), True) for f in s])
def cp_rows(actions):
    rows = []
    for a in actions:
        r = {}
        for k, v in a.items():
            v = dict(v)
            if k == "metaData":
                v["format"] = {"provider": "parquet", "options": []}
                v["configuration"] = list(v.get("configuration", {}).items())
            for m in ("partitionValues", "tags"):
                if isinstance(v.get(m), dict): v[m] = list(v[m].items())
            r[k] = v
        rows.append(r)
    return rows
def write_cp(d, name, actions, schema=None, sub="_delta_log", **kw):
    t = pa.Table.from_pylist(cp_rows(actions), schema=schema or cp_schema())
    p = os.path.join(d, sub, name)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    pq.write_table(t, p, **kw)
    return p
def cpname(v): return "%020d.checkpoint.parquet" % v
def mpname(v, i, n): return "%020d.checkpoint.%010d.%010d.parquet" % (v, i, n)
def last_cp(d, **kw):
    with open(d + "/_delta_log/_last_checkpoint", "w") as f: f.write(json.dumps(kw))

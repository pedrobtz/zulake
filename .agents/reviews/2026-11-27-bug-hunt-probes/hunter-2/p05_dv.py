# deletion vectors: straddles and shapes
from tk import *
from dvtk import *
import copy
DVP = proto(3, 7, ["deletionVectors"], ["deletionVectors"])
def tbl(name, n, dvs):
    """one file of n rows id=0..n-1 per entry of dvs (a descriptor or None)"""
    d = new(name); acts = [ci(), DVP, meta()]
    for i, dv in enumerate(dvs):
        a = data(d, "f%d.parquet" % i, {"id": [i * 1000000 + j for j in range(n)]})
        if dv is not None: a["add"]["deletionVector"] = dv(d) if callable(dv) else dv
        acts.append(a)
    commit(d, 0, acts)
    return d
U = uuid.UUID("61d16c75-6994-46b7-a15b-8b538852e50e")
def ondisk(vals, prefix="", off_delta=0, size_delta=0, card=None, version=1, pre=(), **kw):
    def f(d):
        os.makedirs(d + "/" + prefix, exist_ok=True) if prefix else None
        ds = [dvdata(v) for v in pre] + [dvdata(vals, **kw)]
        pos = dvfile(d + "/" + uname(U, prefix), ds, version)
        o, s = pos[-1]
        return udesc(U, o + off_delta, s + size_delta, len(vals) if card is None else card, prefix)
    return f
tbl("v1", 10, [ondisk([0, 9]), None])
tbl("v1p", 10, [ondisk([0, 9], prefix="ab")])
tbl("v1pre", 10, [ondisk([0, 9], pre=[[1, 2, 3], [4]])])
tbl("v2", 10, [inline([0, 9])])
tbl("v2pad", 10, [inline([0, 9], pad=b"\x07\x07\x07\x07")])
# cardinality formatting: 999, 1000, 100000, 123457
for c in (999, 1000, 100000, 123457):
    tbl("v3_%d" % c, 200000, [ondisk(list(range(0, c)))])
tbl("v3i_100000", 200000, [inline(list(range(1, 200000, 2)))])
# container boundaries
tbl("v4", 70000, [ondisk([65535, 65536, 65537, 69999])])
tbl("v4run", 70000, [ondisk(list(range(65530, 65540)) + [0], runs=True)])
tbl("v4run5", 400000, [ondisk([0, 65536, 131072, 196608, 262144, 399999], runs=True)])
tbl("v4bm", 70000, [ondisk([3, 5, 69999], force_bitmap=True)])
tbl("v4big", 70000, [ondisk(list(range(0, 70000, 3)))])
# rows past the file: n-1 fine, n refused
tbl("v5ok", 10, [ondisk([9])]); tbl("v5past", 10, [ondisk([10])]); tbl("v5far", 10, [ondisk([2**32])]); tbl("v5mix", 10, [ondisk([1, 2**32 + 1])])
# cardinality lies / zero / all rows
tbl("v6less", 10, [ondisk([0, 9], card=1)]); tbl("v6more", 10, [ondisk([0, 9], card=3)]); tbl("v6zero", 10, [ondisk([], card=0)]); tbl("v6all", 10, [ondisk(list(range(10)))])
# offsets and sizes
tbl("v7off0", 10, [ondisk([0, 9], off_delta=-1)]); tbl("v7offp", 10, [ondisk([0, 9], off_delta=1)]); tbl("v7sz", 10, [ondisk([0, 9], size_delta=-1)]); tbl("v7ver", 10, [ondisk([0, 9], version=2)])
def edit(name, src, fn):
    d = ROOT + "/" + name; shutil.rmtree(d, ignore_errors=True); shutil.copytree(ROOT + "/" + src, d)
    p = d + "/_delta_log/" + cname(0); L = [json.loads(x) for x in open(p)]
    for a in L:
        if "add" in a and "deletionVector" in a["add"]: fn(a["add"]["deletionVector"], a["add"])
    open(p, "w").write("\n".join(json.dumps(x) for x in L) + "\n")
edit("v8offfrac", "v1", lambda dv, a: dv.update(offset=1.5))
edit("v8offstr", "v1", lambda dv, a: dv.update(offset="1"))
edit("v8offnull", "v1", lambda dv, a: dv.pop("offset"))
edit("v8szfrac", "v2", lambda dv, a: dv.update(sizeInBytes=36.5))
edit("v8sznone", "v2", lambda dv, a: dv.pop("sizeInBytes"))
edit("v8cardnone", "v2", lambda dv, a: dv.pop("cardinality"))
edit("v8cardfrac", "v2", lambda dv, a: dv.update(cardinality=2.0))
edit("v8sz1e", "v2", lambda dv, a: dv.update(sizeInBytes=3.6e1))
edit("v8inl_off", "v2", lambda dv, a: dv.update(offset=4))
edit("v8szsmall", "v2", lambda dv, a: dv.update(sizeInBytes=32))
edit("v8extra", "v1", lambda dv, a: dv.update(maxRowIndex=9, zzz="q"))
# absolute path DV
def absdv(pfx):
    def f(d):
        pos = dvfile(d + "/abs dv.bin", [dvdata([0, 9])]); o, s = pos[0]
        return {"storageType": "p", "pathOrInlineDv": pfx(d), "offset": o, "sizeInBytes": s, "cardinality": 2}
    return f
tbl("v9abs", 10, [absdv(lambda d: d + "/abs dv.bin")])
tbl("v9file", 10, [absdv(lambda d: "file://" + d + "/abs%20dv.bin")])
tbl("v9absenc", 10, [absdv(lambda d: d + "/abs%20dv.bin")])
# two files, one DV file, two vectors
def share(vals, idx):
    def f(d):
        pos = dvfile(d + "/" + uname(U), [dvdata([0, 9]), dvdata([1, 2, 3])]); o, s = pos[idx]
        return udesc(U, o, s, len(vals))
    return f
tbl("v10", 10, [share([0, 9], 0), share([1, 2, 3], 1)])

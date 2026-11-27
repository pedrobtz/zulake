# hand-written checkpoints whose content differs from the commits (a marker file), to see who reads what
from tk import *
U1 = "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb"; U2 = "cccccccc-1111-4222-8333-dddddddddddd"
def base(name, n=5, p=None):
    d = new(name); adds = []
    for i in range(n):
        a = data(d, "f%d.parquet" % i, {"id": [i]}); adds.append(a)
        commit(d, i, ([ci(), p or proto(), meta()] if i == 0 else [ci()]) + [a])
    return d, adds
def mark(d, tag="m", val=777): return data(d, "mark_%s.parquet" % tag, {"id": [val]})
V2 = proto(3, 7, ["v2Checkpoint"], ["v2Checkpoint"])
d, A = base("k1"); write_cp(d, cpname(2), [proto(), meta(), mark(d), A[1], A[2]])
d, A = base("k2"); write_cp(d, mpname(2, 1, 2), [proto(), meta(), mark(d)]); write_cp(d, mpname(2, 2, 2), [A[1], A[2]])
d, A = base("k3"); write_cp(d, mpname(2, 1, 2), [proto(), meta(), mark(d)])
d, A = base("k4"); write_cp(d, mpname(2, 0, 2), [proto(), meta(), mark(d)]); write_cp(d, mpname(2, 1, 2), [A[1], A[2]])
d, A = base("k5"); write_cp(d, cpname(2), [proto(), meta(), mark(d, "classic", 111)]); write_cp(d, mpname(2, 1, 1), [proto(), meta(), mark(d, "multi", 222)])
# k6: V2 JSON with sidecar
d, A = base("k6", p=V2); sc = write_cp(d, "sc1.parquet", [mark(d), A[1]], sub="_delta_log/_sidecars")
commit(d, 0, [{"checkpointMetadata": {"version": 2}}, V2, meta(), A[2], {"sidecar": {"path": "sc1.parquet", "sizeInBytes": os.path.getsize(sc), "modificationTime": 1}}], name="%020d.checkpoint.%s.json" % (2, U1))
# k7: V2 parquet with sidecar
d, A = base("k7", p=V2); sc = write_cp(d, "sc1.parquet", [mark(d), A[1]], sub="_delta_log/_sidecars")
write_cp(d, "%020d.checkpoint.%s.parquet" % (2, U1), [V2, meta(), A[2], {"sidecar": {"path": "sc1.parquet", "sizeInBytes": os.path.getsize(sc), "modificationTime": 1}}])
# k8: V2 JSON, sidecar missing
d, A = base("k8", p=V2)
commit(d, 0, [{"checkpointMetadata": {"version": 2}}, V2, meta(), A[2], {"sidecar": {"path": "gone.parquet", "sizeInBytes": 10, "modificationTime": 1}}], name="%020d.checkpoint.%s.json" % (2, U1))
# k8b: same, commits 0..2 gone
d, A = base("k8b", p=V2)
commit(d, 0, [{"checkpointMetadata": {"version": 2}}, V2, meta(), A[2], {"sidecar": {"path": "gone.parquet", "sizeInBytes": 10, "modificationTime": 1}}], name="%020d.checkpoint.%s.json" % (2, U1))
for i in range(3): os.remove(d + "/_delta_log/" + cname(i))
# k9: sidecar with protocol/metaData/txn rows inside, and a sidecar row inside the sidecar
d, A = base("k9", p=V2); sc = write_cp(d, "sc1.parquet", [mark(d), A[1], meta([field("id"), field("zz", "string")]), {"txn": {"appId": "sidecar-app", "version": 1}}], sub="_delta_log/_sidecars")
commit(d, 0, [{"checkpointMetadata": {"version": 2}}, V2, meta(), A[2], {"sidecar": {"path": "sc1.parquet", "sizeInBytes": os.path.getsize(sc), "modificationTime": 1}}], name="%020d.checkpoint.%s.json" % (2, U1))
# k10: _last_checkpoint names 2, a newer checkpoint at 3
d, A = base("k10"); write_cp(d, cpname(2), [proto(), meta(), mark(d, "two", 222)]); write_cp(d, cpname(3), [proto(), meta(), mark(d, "three", 333)]); last_cp(d, version=2, size=3)
# k12: truncated checkpoint, commits present
d, A = base("k12"); p = write_cp(d, cpname(2), [proto(), meta(), mark(d)]); b = open(p, "rb").read(); open(p, "wb").write(b[:len(b) // 2])
# k12b: truncated checkpoint named by _last_checkpoint
d, A = base("k12b"); p = write_cp(d, cpname(2), [proto(), meta(), mark(d)]); b = open(p, "rb").read(); open(p, "wb").write(b[:len(b) // 2]); last_cp(d, version=2, size=3)
# k13: checkpoint without protocol row, commits 0..2 gone
d, A = base("k13"); write_cp(d, cpname(2), [meta(), mark(d)])
for i in range(3): os.remove(d + "/_delta_log/" + cname(i))
# k14: one row with add and remove
d, A = base("k14"); m = mark(d); write_cp(d, cpname(2), [proto(), meta(), {"add": m["add"], "remove": rm("mark_m.parquet")["remove"]}, A[1]])
# k15: checkpoint past the last commit
d, A = base("k15"); write_cp(d, cpname(6), [proto(), meta(), mark(d)])
# k16: checkpoint with two adds of one path, one with a dv
dv1 = {"storageType": "i", "pathOrInlineDv": "^Bg9^0rr910000000000iXQKl0rr91000315c8Xg000r9", "sizeInBytes": 36, "cardinality": 2}
DVP = proto(3, 7, ["deletionVectors"], ["deletionVectors"])
d = new("k16"); a = data(d, "f0.parquet", {"id": list(range(10))}); commit(d, 0, [ci(), DVP, meta(), a]); commit(d, 1, [ci()])
import copy; a1 = copy.deepcopy(a); a1["add"]["deletionVector"] = dv1
write_cp(d, cpname(1), [DVP, meta(), a, a1])
# k17: checkpoint with add and remove of one file in two rows
d, A = base("k17"); m = mark(d); write_cp(d, cpname(2), [proto(), meta(), rm("mark_m.parquet"), m, A[1], rm("f1.parquet")])
# k18: checkpoint at 2 plus commit 2 missing (cleaned) but 0,1 present
d, A = base("k18"); write_cp(d, cpname(2), [proto(), meta(), mark(d)]); os.remove(d + "/_delta_log/" + cname(2))
# k19: commits 0..2 gone, ask versions 1, 2, 3
d, A = base("k19"); write_cp(d, cpname(2), [proto(), meta(), mark(d)])
for i in range(3): os.remove(d + "/_delta_log/" + cname(i))
# k20: commits 0..1 gone only (commit 2 kept beside the checkpoint)
d, A = base("k20"); write_cp(d, cpname(2), [proto(), meta(), mark(d)])
for i in range(2): os.remove(d + "/_delta_log/" + cname(i))

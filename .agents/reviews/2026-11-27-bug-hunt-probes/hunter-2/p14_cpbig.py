# big checkpoints, many row groups, sidecars, long keys
from tk import *
from dvtk import *
import copy, random
random.seed(1)
N = 6000
def addrec(i):
    return {"add": {"path": "p=%d/part-%05d-é.parquet" % (i % 7, i), "partitionValues": {"p": str(i % 7) if i % 11 else None}, "size": 100 + i, "modificationTime": 1700000000000 + i, "dataChange": True,
                    "stats": json.dumps({"numRecords": i, "minValues": {"id": i}, "maxValues": {"id": i + 5}, "nullCount": {"id": 0}}), "tags": ({"k%d" % i: "v"} if i % 5 == 0 else None)}}
F = [field("id"), field("p", "integer")]
adds = [addrec(i) for i in range(N)]
for a in adds:
    if a["add"]["tags"] is None: del a["add"]["tags"]
rms = [rm("gone-%d.parquet" % i, deletionTimestamp=1700000000000 + i, extendedFileMetadata=True, partitionValues={"p": "1"}, size=5) for i in range(500)]
txns = [{"txn": {"appId": "app-%d" % i, "version": i, "lastUpdated": 1700000000000 + i}} for i in range(50)]
doms = [{"domainMetadata": {"domain": "dom-%d" % i, "configuration": "{\"i\":%d}" % i, "removed": False}} for i in range(20)]
P = proto(3, 7, ["v2Checkpoint"], ["v2Checkpoint", "domainMetadata"])
allacts = adds + rms + txns + doms
# A: one commit
d = new("big_commit"); commit(d, 0, [ci(), P, meta(F, ["p"])] + allacts)
# B: classic checkpoint only, shuffled rows, small row groups, zstd, data page v2
sh = [P, meta(F, ["p"])] + allacts; random.shuffle(sh)
d = new("big_cp"); write_cp(d, cpname(0), sh, row_group_size=97, compression="zstd", data_page_version="2.0")
# C: multi-part 7 parts
d = new("big_mp")
for k in range(7): write_cp(d, mpname(0, k + 1, 7), sh[k::7], row_group_size=1000, use_dictionary=False, compression="none")
# D: V2 parquet + 5 sidecars
d = new("big_v2"); files = [a for a in sh if "add" in a or "remove" in a]; rest = [a for a in sh if not ("add" in a or "remove" in a)]
scs = []
for k in range(5):
    p = write_cp(d, "sc %d.parquet" % k, files[k::5], sub="_delta_log/_sidecars")
    scs.append({"sidecar": {"path": "sc%%20%d.parquet" % k, "sizeInBytes": os.path.getsize(p), "modificationTime": 1}})
write_cp(d, "%020d.checkpoint.%s.parquet" % (0, "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb"), rest + scs)
# E: V2 json + the same sidecars with raw names
d = new("big_v2json")
scs = []
for k in range(5):
    p = write_cp(d, "sc%d.parquet" % k, files[k::5], sub="_delta_log/_sidecars")
    scs.append({"sidecar": {"path": "sc%d.parquet" % k, "sizeInBytes": os.path.getsize(p), "modificationTime": 1}})
commit(d, 0, [{"checkpointMetadata": {"version": 0}}] + rest + scs, name="%020d.checkpoint.%s.json" % (0, "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb"))
# long inline dv key: add in commit 0 / checkpoint, removed in commit 1
DVP = proto(3, 7, ["deletionVectors"], ["deletionVectors"])
for nm, viacp in (("longkey_commit", False), ("longkey_cp", True)):
    d = new(nm); a = data(d, "f0.parquet", {"id": list(range(60000))}); b = data(d, "f1.parquet", {"id": [-1]})
    big = inline(list(range(0, 60000, 7)))   # array containers -> long Z85
    a1 = copy.deepcopy(a); a1["add"]["deletionVector"] = big
    print(nm, "inline dv chars:", len(big["pathOrInlineDv"]))
    commit(d, 0, [ci(), DVP, meta(), a1, b])
    if viacp: write_cp(d, cpname(0), [DVP, meta(), a1, b]); os.remove(d + "/_delta_log/" + cname(0))
    a2 = copy.deepcopy(a); a2["add"]["deletionVector"] = inline(list(range(0, 60000, 3)))
    commit(d, 1, [ci(), rm("f0.parquet", deletionVector=big), a2])

# a rich table by hand, then deltalake checkpoints of it
from tk import *
import copy, shutil
from deltalake import DeltaTable
dv1 = {"storageType": "i", "pathOrInlineDv": "^Bg9^0rr910000000000iXQKl0rr91000315c8Xg000r9", "sizeInBytes": 36, "cardinality": 2}
F = [field("id"), field("p", "string"), field("q", "integer")]
d = new("k_commits")
a0 = data(d, "p=x/q=1/f0.parquet", {"id": list(range(10))}, pv={"p": "x", "q": "1"})
a0["add"]["stats"] = json.dumps({"numRecords": 10, "minValues": {"id": 0}, "maxValues": {"id": 9}, "nullCount": {"id": 0}})
commit(d, 0, [ci(), proto(3, 7, ["deletionVectors"], ["deletionVectors", "domainMetadata"]), meta(F, ["p", "q"], {"delta.enableDeletionVectors": "true", "k": "v"}), a0,
              {"txn": {"appId": "app1", "version": 5, "lastUpdated": 1700000000000}}, {"txn": {"appId": "app2", "version": 7}}])
a1 = copy.deepcopy(a0); a1["add"]["deletionVector"] = dv1
commit(d, 1, [ci(), rm("p=x/q=1/f0.parquet", extendedFileMetadata=True, partitionValues={"p": "x", "q": "1"}, size=a0["add"]["size"]), a1,
              {"domainMetadata": {"domain": "d1", "configuration": "{\"a\":1}", "removed": False}},
              {"domainMetadata": {"domain": "d2", "configuration": "c2", "removed": False}}])
b = data(d, "p=__HIVE_DEFAULT_PARTITION__/q=2/f1.parquet", {"id": [100, 101]}, pv={"p": None, "q": "2"}, tags={"t1": "v1", "t2": None})
c = data(d, "f2.parquet", {"id": [200]}, pv={"p": "", "q": None}, stats=False)
commit(d, 2, [ci(), b, c, {"txn": {"appId": "app1", "version": 9007199254740993, "lastUpdated": 1700000000001}},
              {"domainMetadata": {"domain": "d2", "configuration": "c2", "removed": True}}])
e = data(d, "p=y/q=3/f3.parquet", {"id": [300]}, pv={"p": "y", "q": "3"})
commit(d, 3, [ci(), e, rm("f2.parquet")])
g = data(d, "p=y/q=3/f4.parquet", {"id": [400]}, pv={"p": "y", "q": "3"})
commit(d, 4, [ci(), g])
# B: checkpoint at 3 by deltalake (open at version 3), commits kept
B = ROOT + "/k_cp"; shutil.rmtree(B, ignore_errors=True); shutil.copytree(d, B)
try:
    dt = DeltaTable(B, version=3); dt.create_checkpoint(); print("checkpoint ok", sorted(os.listdir(B + "/_delta_log")))
except BaseException as ex:
    print("checkpoint failed:", ex)
# C: commits 0..3 removed
C = ROOT + "/k_cponly"; shutil.rmtree(C, ignore_errors=True); shutil.copytree(B, C)
for i in range(4): os.remove(C + "/_delta_log/" + cname(i))
sys.stdout.flush(); os._exit(0)

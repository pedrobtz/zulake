# log compaction files
from tk import *
def comp(d, x, y, actions): return commit(d, 0, actions, name="%020d.%020d.compacted.json" % (x, y))
def base(name, n=5):
    d = new(name); adds = []
    for i in range(n):
        a = data(d, "f%d.parquet" % i, {"id": [i]}); adds.append(a)
        commit(d, i, ([ci(), proto(), meta()] if i == 0 else [ci()]) + [a])
    return d, adds
# c2: compaction 1-3 drops f2's add: shows who reads the compaction
d, A = base("c2"); comp(d, 1, 3, [A[1], A[3]])
# c3: same, read at version 2: compaction must not be used
# c4: overlapping: 1-2 (drops f1), 1-3 (drops f2), 2-3 (drops f3)
d, A = base("c4"); comp(d, 1, 2, [A[2]]); comp(d, 1, 3, [A[1], A[3]]); comp(d, 2, 3, [A[2]])
# c5: compaction 1-3 valid, commits 1..3 deleted
d, A = base("c5"); comp(d, 1, 3, [A[1], A[2], A[3]])
for i in (1, 2, 3): os.remove(d + "/_delta_log/" + cname(i))
# c6: compaction 0-2 with protocol+metaData, commits 0..2 deleted
d, A = base("c6"); comp(d, 0, 2, [proto(), meta(), A[0], A[1], A[2]])
for i in (0, 1, 2): os.remove(d + "/_delta_log/" + cname(i))
# c7: compaction past the last commit: 3-6 (drops f3)
d, A = base("c7"); comp(d, 3, 6, [A[4]])
# c8: compaction 1-3 corrupt JSON, commits present
d, A = base("c8"); commit(d, 0, [], name="%020d.%020d.compacted.json" % (1, 3), raw='{"add":{"path":\n')
# c9: compaction 1-3 holds add and remove of f1 (f1 added in 1, removed in 3 -> reconciled keeps remove only; here both)
d, A = base("c9"); commit(d, 5, [rm("f1.parquet")])
# c10: compaction 1-2 that removes f0 while commits do not (to see precedence), read at version 2,3,4
d, A = base("c10"); comp(d, 1, 2, [A[1], A[2], rm("f0.parquet")])
# c11: compaction 1-3 with a metaData that the commits lack (schema change)
d, A = base("c11"); comp(d, 1, 3, [A[1], A[2], A[3], meta([field("id"), field("zz", "string")])])
# c12: compaction 1-3 with two removes for same path (f0 with dv-less and with dv key) as reconciled result of dv updates
dv1 = {"storageType": "i", "pathOrInlineDv": "^Bg9^0rr910000000000iXQKl0rr91000315c8Xg000r9", "sizeInBytes": 36, "cardinality": 2}
d = new("c12")
a = data(d, "f0.parquet", {"id": list(range(10))})
commit(d, 0, [ci(), proto(3, 7, ["deletionVectors"], ["deletionVectors"]), meta(), a])
import copy
a1 = copy.deepcopy(a); a1["add"]["deletionVector"] = dv1
commit(d, 1, [ci(), rm("f0.parquet"), a1])
b = data(d, "f1.parquet", {"id": [100]})
commit(d, 2, [ci(), rm("f0.parquet", deletionVector=dv1), b])
comp(d, 1, 2, [rm("f0.parquet"), rm("f0.parquet", deletionVector=dv1), b])

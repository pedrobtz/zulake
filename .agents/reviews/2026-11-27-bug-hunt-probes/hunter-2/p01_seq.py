# sequences: reconciliation orders
from tk import *
def base(name):
    d = new(name)
    a = data(d, "a.parquet", {"id": [1, 2]}); b = data(d, "b.parquet", {"id": [3]})
    commit(d, 0, [ci(), proto(), meta(), a, b])
    return d, a, b
# s1: remove then re-add across commits
d, a, b = base("s1"); commit(d, 1, [rm("a.parquet")]); commit(d, 2, [a])
# s2: remove of a file never added, then add later
d, a, b = base("s2"); c = data(d, "c.parquet", {"id": [9]}); commit(d, 1, [rm("c.parquet")]); commit(d, 2, [c])
# s3: add the same file again in a later commit (no remove) with other stats
d, a, b = base("s3"); commit(d, 1, [a])
# s4: path encodings: "a%2Eparquet" removes "a.parquet"?
d, a, b = base("s4"); commit(d, 1, [rm("a%2Eparquet")])
# s5: remove with ./ prefix
d, a, b = base("s5"); commit(d, 1, [rm("./a.parquet")])
# s6: metaData mid-log changes schema: adds column
d, a, b = base("s6"); c = data(d, "c.parquet", {"id": [9], "x": ["u"]}); commit(d, 1, [meta([field("id"), field("x", "string")]), c])
# s7: protocol mid-log upgraded to unsupported feature, then version 0 still readable
d, a, b = base("s7"); commit(d, 1, [proto(3, 7, ["typeWidening"], ["typeWidening"])])
# s8: one line holding two actions
d, a, b = base("s8"); c = data(d, "c.parquet", {"id": [9]}); commit(d, 1, [{"add": c["add"], "remove": rm("a.parquet")["remove"]}])
# s9: commit 1 is empty file
d, a, b = base("s9"); commit(d, 1, [], raw=""); c = data(d, "c.parquet", {"id": [9]}); commit(d, 2, [c])
# s10: add with dataChange false and unknown action + unknown fields
d, a, b = base("s10"); c = data(d, "c.parquet", {"id": [9]}, tags={"k": "v"}, baseRowId=5, defaultRowCommitVersion=1, clusteringProvider="x", zzz={"q": [1]}); commit(d, 1, [{"futureAction": {"path": "a.parquet"}}, c, {"cdc": {"path": "cdc.parquet", "partitionValues": {}, "size": 1, "dataChange": False}}])
# s11: add with path having spaces percent-encoded
d = new("s11"); a = data(d, "x y/a b.parquet", {"id": [1]}); a["add"]["path"] = "x%20y/a%20b.parquet"; commit(d, 0, [proto(), meta(), a])
# s12: path with literal percent in file name "a%20b.parquet" on disk -> encoded "a%2520b.parquet"
d = new("s12"); a = data(d, "a%20b.parquet", {"id": [1]}); a["add"]["path"] = "a%2520b.parquet"; commit(d, 0, [proto(), meta(), a])
# s13: unencoded space and plus and unicode
d = new("s13"); a = data(d, "a b+c é.parquet", {"id": [1]}); commit(d, 0, [proto(), meta(), a])
# s14: gap in versions 0,1,3
d, a, b = base("s14"); commit(d, 1, [rm("a.parquet")]); commit(d, 3, [rm("b.parquet")])
# s15: log starts at version 1 without checkpoint
d = new("s15"); a = data(d, "a.parquet", {"id": [1]}); commit(d, 1, [proto(), meta(), a])

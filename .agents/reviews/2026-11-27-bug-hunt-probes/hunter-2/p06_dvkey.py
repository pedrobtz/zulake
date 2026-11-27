# the logical-file key (path, dv id) across log shapes
from tk import *
from dvtk import *
import copy
DVP = proto(3, 7, ["deletionVectors"], ["deletionVectors"])
U = uuid.UUID("61d16c75-6994-46b7-a15b-8b538852e50e")
def base(name):
    d = new(name)
    a = data(d, "f0.parquet", {"id": list(range(10))})
    pos = dvfile(d + "/" + uname(U), [dvdata([0, 9]), dvdata([1, 2, 3])])
    dvA = udesc(U, pos[0][0], pos[0][1], 2); dvB = udesc(U, pos[1][0], pos[1][1], 3)
    commit(d, 0, [ci(), DVP, meta(), a])
    a1 = copy.deepcopy(a); a1["add"]["deletionVector"] = dvA
    commit(d, 1, [ci(), rm("f0.parquet"), a1])
    a2 = copy.deepcopy(a); a2["add"]["deletionVector"] = dvB
    return d, a, a1, a2, dvA, dvB
def raw(o): return json.dumps(o)
# q1: normal dv update
d, a, a1, a2, dvA, dvB = base("q1"); commit(d, 2, [ci(), rm("f0.parquet", deletionVector=dvA), a2])
# q2: remove's offset written 1.0
d, a, a1, a2, dvA, dvB = base("q2"); commit(d, 2, [ci(), raw(rm("f0.parquet", deletionVector=dvA)).replace('"offset": 1,', '"offset": 1.0,'), a2])
# q3: remove's offset written 1e0
d, a, a1, a2, dvA, dvB = base("q3"); commit(d, 2, [ci(), raw(rm("f0.parquet", deletionVector=dvA)).replace('"offset": 1,', '"offset": 1e0,'), a2])
# q4: remove without the dv (names the path only)
d, a, a1, a2, dvA, dvB = base("q4"); commit(d, 2, [ci(), rm("f0.parquet"), a2])
# q5: remove with dv whose sizeInBytes/cardinality differ (id is the same)
d, a, a1, a2, dvA, dvB = base("q5"); x = dict(dvA, sizeInBytes=1, cardinality=77); commit(d, 2, [ci(), rm("f0.parquet", deletionVector=x), a2])
# q6: escapes in path and key order / whitespace
d, a, a1, a2, dvA, dvB = base("q6"); commit(d, 2, [ci(), '  {  "remove" : {"deletionVector": %s , "dataChange":true, "path":"f\\u0030.parquet"}}  ' % raw(dvA), '\t' + raw(a2)])
# q7: checkpoint at 1 (by hand) then the dv update
d, a, a1, a2, dvA, dvB = base("q7"); write_cp(d, cpname(1), [DVP, meta(), a1]); commit(d, 2, [ci(), rm("f0.parquet", deletionVector=dvA), a2])
for i in (0, 1): os.remove(d + "/_delta_log/" + cname(i))
# q8: remove of plain file, then re-add of plain file while dv version live? (dv removed, restored)
d, a, a1, a2, dvA, dvB = base("q8"); commit(d, 2, [ci(), rm("f0.parquet", deletionVector=dvA), a])
# q9: commit 2 only adds a2 (no remove): two logical files of one path across commits
d, a, a1, a2, dvA, dvB = base("q9"); commit(d, 2, [ci(), a2])
# q10: CRLF line endings and a BOM and blank lines
d, a, a1, a2, dvA, dvB = base("q10"); commit(d, 2, [], raw="\r\n" + raw(ci()) + "\r\n\r\n" + raw(rm("f0.parquet", deletionVector=dvA)) + "\r\n" + raw(a2) + "\r\n   \r\n")
d, a, a1, a2, dvA, dvB = base("q11"); commit(d, 2, [], raw="﻿" + raw(ci()) + "\n" + raw(rm("f0.parquet", deletionVector=dvA)) + "\n" + raw(a2))
# q12: non-ASCII escapes in path: file "é.parquet" added raw, removed as é, and as percent-encoded
d = new("q12"); a = data(d, "é.parquet", {"id": [1]}); b = data(d, "b.parquet", {"id": [2]}); commit(d, 0, [ci(), proto(), meta(), a, b]); commit(d, 1, [ci(), '{"remove":{"path":"\\u00e9.parquet","dataChange":true}}'])
d = new("q13"); a = data(d, "é.parquet", {"id": [1]}); b = data(d, "b.parquet", {"id": [2]}); commit(d, 0, [ci(), proto(), meta(), a, b]); commit(d, 1, [ci(), '{"remove":{"path":"%C3%A9.parquet","dataChange":true}}'])
# q14: NFD vs NFC forms of é
d = new("q14"); a = data(d, "é.parquet", {"id": [1]}); b = data(d, "b.parquet", {"id": [2]}); commit(d, 0, [ci(), proto(), meta(), a, b]); commit(d, 1, [ci(), '{"remove":{"path":"e\\u0301.parquet","dataChange":true}}'])

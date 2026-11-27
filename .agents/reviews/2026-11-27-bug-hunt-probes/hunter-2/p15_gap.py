# gaps, corrupt later commits, checkpoint rows that are not actions
from tk import *
def base(name, n=5):
    d = new(name); adds = []
    for i in range(n):
        a = data(d, "f%d.parquet" % i, {"id": [i]}); adds.append(a)
        commit(d, i, ([ci(), proto(), meta()] if i == 0 else [ci()]) + [a])
    return d, adds
d, A = base("h_gap_after_cp"); write_cp(d, cpname(2), [proto(), meta(), A[0], A[1], A[2]]); os.remove(d + "/_delta_log/" + cname(3))
d, A = base("h_stray"); commit(d, 9, [ci(), rm("f0.parquet")])
d, A = base("h_corrupt_last"); commit(d, 4, [], raw='{"add":{"path":"f4.parquet","size":')
d, A = base("h_corrupt_mid"); commit(d, 2, [], raw='{"add":{"path":"f4.parquet","size":')
d, A = base("h_corrupt_mid_cp"); commit(d, 2, [], raw='garbage'); write_cp(d, cpname(3), [proto(), meta(), A[0], A[1], A[2], A[3]])
d, A = base("h_cp_nullpath"); x = {"add": dict(A[1]["add"], path=None)}; write_cp(d, cpname(2), [proto(), meta(), A[0], x, A[2]])
d, A = base("h_cp_domtomb"); write_cp(d, cpname(2), [proto(), meta(), A[0], A[1], A[2], {"domainMetadata": {"domain": "d", "configuration": "c", "removed": True}}, {"domainMetadata": {"domain": "e", "configuration": "c", "removed": False}}])
d, A = base("h_cp_twoproto"); write_cp(d, cpname(2), [proto(), proto(3, 7, ["typeWidening"], ["typeWidening"]), meta(), A[0], A[1], A[2]])
d, A = base("h_cp_emptyrows"); write_cp(d, cpname(2), [proto(), {}, meta(), {}, A[0], A[1], A[2], {}])
d, A = base("h_cp_zero"); write_cp(d, cpname(2), [])
d, A = base("h_nul"); commit(d, 4, [], raw=json.dumps(ci()) + "\n" + json.dumps(A[4]).replace("f4.parquet", "f4\\u0000.parquet") + "\n")

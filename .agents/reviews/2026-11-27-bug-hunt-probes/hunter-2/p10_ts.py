# time travel by timestamp: file times and in-commit timestamps
from tk import *
BASE = 1700000000000  # ms
def mt(d, v, ms): os.utime(d + "/_delta_log/" + cname(v), (ms / 1000, ms / 1000))
ICTP = proto(1, 7, None, ["inCommitTimestamp"])
def build(name, times, ict=None, conf=None, p=None, cis=None, n=None):
    """times: file time per version (ms offsets); ict: in-commit time per version (or None)"""
    d = new(name); n = n or len(times)
    for i in range(n):
        a = data(d, "f%d.parquet" % i, {"id": [i]})
        c = ci() if ict is None or ict[i] is None else ci(BASE + ict[i])
        if cis and i in cis: c = cis[i]
        acts = [c] + ([p or proto(), meta(conf=conf)] if i == 0 else []) + [a]
        if c is None: acts = acts[1:]
        commit(d, i, acts)
    for i in range(n): mt(d, i, BASE + times[i])
    return d
build("t1", [0, 1000, 2000, 3000])
build("t2", [0, 3000, 1000, 2000])                      # not monotonic
build("t2b", [5000, 5000, 5000, 5000])                  # all equal
EN = {"delta.enableInCommitTimestamps": "true"}
build("t3", [9000, 8000, 7000, 6000], ict=[0, 1000, 2000, 3000], conf=EN, p=ICTP)
# t4: enabled at version 2
d = build("t4", [0, 1000, 500000, 600000], ict=[None, None, 2000, 3000], p=ICTP)
p = d + "/_delta_log/" + cname(2); L = open(p).read().splitlines()
L.insert(1, json.dumps(meta(conf=dict(EN, **{"delta.inCommitTimestampEnablementVersion": "2", "delta.inCommitTimestampEnablementTimestamp": str(BASE + 2000)}))))
open(p, "w").write("\n".join(L) + "\n"); mt(d, 2, BASE + 500000)
# t5: ICT enabled, commit 2 lacks it / not first / fraction / string
build("t5_missing", [0, 1000, 2000, 3000], ict=[0, 1000, None, 3000], conf=EN, p=ICTP)
d = build("t5_notfirst", [0, 1000, 2000, 3000], ict=[0, 1000, 2000, 3000], conf=EN, p=ICTP)
p = d + "/_delta_log/" + cname(2); L = open(p).read().splitlines(); open(p, "w").write("\n".join(L[::-1]) + "\n"); mt(d, 2, BASE + 2000)
build("t5_frac", [0, 1000, 2000, 3000], ict=[0, 1000, 2000, 3000], conf=EN, p=ICTP, cis={2: ci(BASE + 2000.5)})
build("t5_str", [0, 1000, 2000, 3000], ict=[0, 1000, 2000, 3000], conf=EN, p=ICTP, cis={2: ci(str(BASE + 2000))})
build("t5_back", [0, 1000, 2000, 3000], ict=[0, 3000, 1000, 2000], conf=EN, p=ICTP)   # ICT not monotonic
# t6: property true but feature not in writerFeatures
build("t6_nofeat", [9000, 8000, 7000, 6000], ict=[0, 1000, 2000, 3000], conf=EN)
# t7: early commits gone, checkpoint at 2 / commit 2 kept or not
d = build("t7", [0, 1000, 2000, 3000, 4000]); write_cp(d, cpname(3), [proto(), meta(), data(d, "mark.parquet", {"id": [777]})])
for i in (0, 1): os.remove(d + "/_delta_log/" + cname(i))
d = build("t8", [0, 1000, 2000, 3000, 4000]); write_cp(d, cpname(2), [proto(), meta(), data(d, "mark.parquet", {"id": [777]})])
for i in (0, 1, 2): os.remove(d + "/_delta_log/" + cname(i))

# before the error: data files that fail part-way
from tk import *
def base(name):
    d = new(name); adds = []
    for i in range(3):
        adds.append(data(d, "f%d.parquet" % i, {"id": list(range(i * 1000, i * 1000 + 1000)), "s": ["x" * 20 + str(j) for j in range(1000)]}))
    commit(d, 0, [ci(), proto(), meta([field("id"), field("s", "string")])] + adds)
    return d
d = base("b_missing"); os.remove(d + "/f1.parquet")
d = base("b_trunc"); b = open(d + "/f1.parquet", "rb").read(); open(d + "/f1.parquet", "wb").write(b[:len(b) // 2])
d = base("b_page"); b = bytearray(open(d + "/f1.parquet", "rb").read())
for i in range(40, 400): b[i] ^= 0xFF
open(d + "/f1.parquet", "wb").write(bytes(b))
d = base("b_empty"); open(d + "/f1.parquet", "wb").write(b"")
d = base("b_dir"); os.remove(d + "/f1.parquet"); os.makedirs(d + "/f1.parquet")
d = base("b_notparquet"); open(d + "/f1.parquet", "wb").write(b"PAR1 this is not parquet PAR1")

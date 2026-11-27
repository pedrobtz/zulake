# usage: python3 cmp.py out.txt -- zulake and deltalake blocks side by side
import re, sys
s = open(sys.argv[1]).read()
z, d = s.split("==== deltalake")
def blocks(t):
    out = {}
    for b in re.split(r"\n(?=## )", t):
        if b.startswith("## "):
            k = b.split("\n")[0][3:].strip(); body = b.split("\n")[1:]
            out[k] = [x.strip()[:int(sys.argv[2]) if len(sys.argv) > 2 else 300] for x in body if x.strip() and not x.strip().startswith("version:")]
    return out
Z, D = blocks(z), blocks(d)
for k in Z:
    print(k)
    for x in Z[k]: print("   Z:", x)
    for x in D.get(k, []): print("   D:", x)

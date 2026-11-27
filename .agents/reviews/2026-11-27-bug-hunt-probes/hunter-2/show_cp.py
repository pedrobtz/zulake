import sys, pyarrow.parquet as pq
t = pq.read_table(sys.argv[1])
print(t.schema)
for r in t.to_pylist(): print({k: v for k, v in r.items() if v is not None})

# usage: python d.py <table>[@version] ... -- deltalake's view (one subprocess per table, 40 s limit)
import sys, os, subprocess, warnings
warnings.simplefilter('ignore')
def one(arg):
    from deltalake import DeltaTable
    p = arg.split("@")
    try:
        dt = DeltaTable(p[0], version=int(p[1]) if len(p) > 1 else None)
        print("  version:", dt.version(), " files:", " ".join(sorted(os.path.basename(f) for f in dt.file_uris())), flush=True)
        t = dt.to_pyarrow_table(engine="datafusion")
        print("  cols:", " ".join(f"{f.name}:{f.type}" for f in t.schema))
        rows = sorted("|".join(str(v) for v in r.values()) for r in t.to_pylist())
        print("  rows(%d):" % t.num_rows, " ; ".join(rows[:14]), flush=True)
    except BaseException as e:
        print("  ERROR", type(e).__name__, str(e)[:260].replace("\n", " "), flush=True)
if sys.argv[1] == "--one":
    one(sys.argv[2])
    sys.stdout.flush(); os._exit(0)
else:
    for arg in sys.argv[1:]:
        p = arg.split("@")
        print("##", os.path.basename(p[0]), "@" + p[1] if len(p) > 1 else "", flush=True)
        try:
            subprocess.run([sys.executable, __file__, "--one", arg], timeout=40)
        except subprocess.TimeoutExpired:
            print("  HANG (killed after 40 s)", flush=True)

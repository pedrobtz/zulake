# usage: python td.py <table> <offset ms>... -- version deltalake opens at BASE + offset
import sys, os, datetime, warnings
warnings.simplefilter("ignore")
from deltalake import DeltaTable
BASE = 1700000000000
T = os.path.dirname(os.path.abspath(__file__)) + "/t/"
print("##", sys.argv[1])
try:
    dt = DeltaTable(T + sys.argv[1]); print("  history:", " ".join("%s=%s" % (h.get("version"), h.get("timestamp") - BASE) for h in sorted(dt.history(), key=lambda h: h["version"])))
except BaseException as e: print("  open ERROR", str(e)[:200])
for o in sys.argv[2:]:
    try:
        dt = DeltaTable(T + sys.argv[1]); dt.load_as_version(datetime.datetime.fromtimestamp((BASE + float(o)) / 1000, tz=datetime.timezone.utc)); print("  ", o, "->", dt.version())
    except BaseException as e: print("  ", o, "-> ERROR", str(e)[:150].replace("\n", " "))
sys.stdout.flush(); os._exit(0)

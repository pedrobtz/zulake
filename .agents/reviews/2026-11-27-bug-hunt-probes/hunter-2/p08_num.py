# numbers in log fields
from tk import *
import copy
def one(name, edit_add=None, extra=(), stats=None, raw_add=None):
    d = new(name); a = data(d, "f0.parquet", {"id": [1, 2, 3]}); b = data(d, "f1.parquet", {"id": [4, 5]})
    if stats is not None: a["add"]["stats"] = stats
    if edit_add: edit_add(a["add"])
    line = json.dumps(a) if raw_add is None else raw_add(json.dumps(a))
    commit(d, 0, [ci(), proto(), meta(), line, b] + list(extra))
    return d
S = lambda **k: json.dumps(k)
one("n_ok")
one("n_size_neg", lambda a: a.update(size=-1)); one("n_size_frac", lambda a: a.update(size=1.5)); one("n_size_str", lambda a: a.update(size="486"))
one("n_size_null", lambda a: a.update(size=None)); one("n_size_big", raw_add=lambda s: s.replace('"size": ', '"size": 9223372036854775808999, "x": '))
one("n_size_exp", raw_add=lambda s: s.replace('"size": ', '"size": 4.86e2, "x": ')); one("n_size_zero", lambda a: a.update(size=0)); one("n_size_wrong", lambda a: a.update(size=a["size"] + 1))
one("n_mt_neg", lambda a: a.update(modificationTime=-1)); one("n_mt_frac", lambda a: a.update(modificationTime=1.5)); one("n_mt_str", lambda a: a.update(modificationTime="x")); one("n_mt_none", lambda a: a.pop("modificationTime"))
one("n_mt_big", raw_add=lambda s: s.replace('"modificationTime": 1000', '"modificationTime": 9223372036854775807'))
one("n_dc_none", lambda a: a.pop("dataChange")); one("n_dc_str", lambda a: a.update(dataChange="yes"))
one("n_nr_neg", stats=S(numRecords=-1)); one("n_nr_frac", stats=S(numRecords=2.5)); one("n_nr_str", stats=S(numRecords="3")); one("n_nr_null", stats=S(numRecords=None))
one("n_nr_exp", stats='{"numRecords":3e0}'); one("n_nr_big", stats='{"numRecords":9007199254740993}'); one("n_nr_huge", stats='{"numRecords":1e30}'); one("n_nr_wrong", stats=S(numRecords=1000))
one("n_stats_bad", stats='{"numRecords":'); one("n_stats_arr", stats='[1]'); one("n_stats_empty", stats=''); one("n_stats_obj", lambda a: a.update(stats={"numRecords": 3})); one("n_stats_num", lambda a: a.update(stats=3))
T = lambda **k: {"txn": dict(appId="a", **k)}
one("n_txn_neg", extra=[T(version=-1)]); one("n_txn_frac", extra=[T(version=1.5)]); one("n_txn_str", extra=[T(version="1")]); one("n_txn_big", extra=['{"txn":{"appId":"a","version":9223372036854775808}}'])
one("n_txn_lu", extra=[T(version=1, lastUpdated=1.5)]); one("n_txn_lus", extra=[T(version=1, lastUpdated="x")]); one("n_txn_two", extra=[T(version=5), T(version=3)])

"""deltalake 1.7.0's answers for every fixture table at every version.

    cd tools/oracle && uv run --frozen python answers.py

For each table under tests/testthat/fixtures/tables/ and each version from 0
to the last one its _delta_log/ records, writes
tests/testthat/fixtures/answers/<table>/<version>.json. The files are
deterministic: sorted keys, rows in a fixed order, table paths replaced by
"<table>", and nothing about the run itself, so .github/workflows/oracle.yaml
regenerates them and fails on any diff. README.md in this directory gives the
fields and the value encoding.
"""

import datetime as dt
import decimal
import json
import math
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

import deltalake
import pyarrow as pa
import pyarrow.parquet as pq
from deltalake import DeltaTable

DELTALAKE_VERSION = "1.7.0"
ENGINE = "datafusion"
ROOT = Path(__file__).resolve().parents[2]
TABLES = ROOT / "tests" / "testthat" / "fixtures" / "tables"
ANSWERS = ROOT / "tests" / "testthat" / "fixtures" / "answers"
MAX_EXACT = 2**53 - 1
EPOCH_ORDINAL = dt.date(1970, 1, 1).toordinal()
UNIT_DIGITS = {"s": 0, "ms": 3, "us": 6, "ns": 9}
COMMIT = re.compile(r"^(\d{20})\.json$")
CHECKPOINT = re.compile(r"^(\d{20})\.checkpoint(\.\d{10}\.\d{10}|\.[0-9a-f-]{36})?\.(parquet|json)$")


# ---- value encoding (README.md, "Encoding") ------------------------------


def json_value(x):
    """Plain JSON from a parsed log: integers past 2^53 - 1 become strings."""
    if isinstance(x, bool) or x is None or isinstance(x, str):
        return x
    if isinstance(x, int):
        return str(x) if abs(x) > MAX_EXACT else x
    if isinstance(x, float):
        return float_value(x)
    if isinstance(x, dict):
        return {k: json_value(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [json_value(v) for v in x]
    raise TypeError(f"unexpected {type(x).__name__} in log JSON")


def float_value(x):
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    return x


def civil(days):
    return dt.date.fromordinal(EPOCH_ORDINAL + days)


def timestamp_text(value, unit, utc):
    digits = UNIT_DIGITS[unit]
    per_second = 10**digits
    seconds, frac = divmod(value, per_second)
    days, sod = divmod(seconds, 86400)
    hh, rest = divmod(sod, 3600)
    mm, ss = divmod(rest, 60)
    try:
        date = civil(days).isoformat()
    except (ValueError, OverflowError):
        return f"{value} {unit}"
    text = f"{date}T{hh:02d}:{mm:02d}:{ss:02d}"
    if digits:
        text += "." + str(frac).zfill(digits)
    return text + ("Z" if utc else "")


def encode_array(arr):
    """One Arrow array as a list of JSON values, by its type."""
    t = arr.type
    if pa.types.is_dictionary(t):
        return encode_array(arr.dictionary_decode())
    valid = arr.is_valid().to_pylist() if len(arr) else []
    if pa.types.is_null(t):
        return [None] * len(arr)
    if pa.types.is_struct(t):
        fields = {t.field(i).name: encode_array(arr.field(i)) for i in range(t.num_fields)}
        return [{k: fields[k][j] for k in fields} if valid[j] else None for j in range(len(arr))]
    if pa.types.is_map(t):
        out = []
        for j in range(len(arr)):
            if not valid[j]:
                out.append(None)
                continue
            entries = arr[j].values
            if entries is None or len(entries) == 0:
                out.append([])
                continue
            keys = encode_array(entries.field(0))
            values = encode_array(entries.field(1))
            out.append([[k, v] for k, v in zip(keys, values)])
        return out
    if pa.types.is_list(t) or pa.types.is_large_list(t) or pa.types.is_fixed_size_list(t) or \
            (hasattr(pa.types, "is_list_view") and (pa.types.is_list_view(t) or pa.types.is_large_list_view(t))):
        return [encode_array(arr[j].values) if valid[j] else None for j in range(len(arr))]
    if pa.types.is_timestamp(t):
        ints = arr.cast(pa.int64()).to_pylist()
        return [None if v is None else timestamp_text(v, t.unit, t.tz is not None) for v in ints]
    if pa.types.is_date32(t):
        return [None if v is None else civil(v).isoformat() for v in arr.cast(pa.int32()).to_pylist()]
    if pa.types.is_date64(t):
        return [None if v is None else civil(v // 86400000).isoformat() for v in arr.cast(pa.int64()).to_pylist()]
    if pa.types.is_decimal(t):
        return [None if v is None else format(v, "f") for v in arr.to_pylist()]
    if pa.types.is_binary(t) or pa.types.is_large_binary(t) or pa.types.is_fixed_size_binary(t) or \
            (hasattr(pa.types, "is_binary_view") and pa.types.is_binary_view(t)):
        return [None if v is None else v.hex() for v in arr.to_pylist()]
    if t in (pa.int64(), pa.uint32(), pa.uint64()):
        return [None if v is None else str(v) for v in arr.to_pylist()]
    if pa.types.is_floating(t):
        return [None if v is None else float_value(v) for v in arr.to_pylist()]
    if pa.types.is_integer(t) or pa.types.is_boolean(t) or pa.types.is_string(t) or \
            pa.types.is_large_string(t) or (hasattr(pa.types, "is_string_view") and pa.types.is_string_view(t)):
        return arr.to_pylist()
    raise TypeError(f"no encoding for Arrow type {t}")


def type_text(t):
    """Arrow type name, with the view and large variants named as their plain type."""
    text = str(t)
    for old, new in (("large_string", "string"), ("string_view", "string"), ("large_binary", "binary"),
                     ("binary_view", "binary"), ("large_list", "list")):
        text = text.replace(old, new)
    return text


def encode_table(table, sort_by=None):
    """A table as {schema, num_rows, columns}, its rows sorted."""
    table = table.combine_chunks() if table.num_rows else table
    cols = [encode_array(table.column(i).combine_chunks() if table.column(i).num_chunks else
                         pa.array([], table.schema.field(i).type)) for i in range(table.num_columns)]
    n = table.num_rows
    if sort_by is not None:
        key_cols = [cols[table.schema.get_field_index(c)] for c in sort_by]
    else:
        key_cols = cols
    keys = [json.dumps([c[j] for c in key_cols], sort_keys=True) for j in range(n)]
    order = sorted(range(n), key=lambda j: (keys[j], json.dumps([c[j] for c in cols], sort_keys=True)))
    return {
        "schema": [{"name": f.name, "type": type_text(f.type), "nullable": f.nullable} for f in table.schema],
        "num_rows": n,
        "columns": {table.schema.field(i).name: [cols[i][j] for j in order] for i in range(table.num_columns)},
    }


# ---- one table -----------------------------------------------------------


class Scrub:
    """Replaces every spelling of the scratch copy's location with "<table>"."""

    def __init__(self, path):
        real = os.path.realpath(path)
        spellings = {path, real, "/private" + path if path.startswith("/tmp") else path}
        self.patterns = sorted({f"file://{s}" for s in spellings} | spellings, key=len, reverse=True)

    def __call__(self, text):
        for p in self.patterns:
            text = text.replace(p, "<table>")
        return text

    def relative(self, uri):
        text = self(uri)
        return text[len("<table>/"):] if text.startswith("<table>/") else text


def error(e, scrub):
    return {"error": {"class": type(e).__name__, "message": scrub(str(e))}}


def log_versions(table_dir):
    versions = set()
    for name in os.listdir(table_dir / "_delta_log"):
        m = COMMIT.match(name) or CHECKPOINT.match(name)
        if m:
            versions.add(int(m.group(1)))
    return sorted(versions)


def read_commit(table_dir, version):
    f = table_dir / "_delta_log" / f"{version:020d}.json"
    if not f.exists():
        return None
    return [json_value(json.loads(line)) for line in f.read_text(encoding="utf-8").splitlines() if line.strip()]


def app_ids(table_dir):
    """Every txn appId the log mentions, from commits and checkpoints, by our own parse."""
    ids = set()
    log = table_dir / "_delta_log"
    for name in os.listdir(log):
        if COMMIT.match(name):
            for line in (log / name).read_text(encoding="utf-8").splitlines():
                if line.strip():
                    a = json.loads(line)
                    if "txn" in a:
                        ids.add(a["txn"]["appId"])
    for f in list(log.glob("*.checkpoint*.parquet")) + list((log / "_sidecars").glob("*.parquet")):
        schema = pq.read_schema(f)
        if "txn" in schema.names:
            for row in pq.read_table(f, columns=["txn"]).column("txn").to_pylist():
                if row and row.get("appId"):
                    ids.add(row["appId"])
    return sorted(ids)


def set_commit_mtimes(path):
    """Each commit file's modification time set to its commitInfo.timestamp.

    The protocol resolves a timestamp to a version by the commit file's
    modification time when inCommitTimestamp is off, and git does not keep
    modification times, so the harness fixes them to the time the commit
    itself records. Stage 2 does the same before comparing.
    """
    log = Path(path) / "_delta_log"
    for name in os.listdir(log):
        if COMMIT.match(name):
            for line in (log / name).read_text(encoding="utf-8").splitlines():
                a = json.loads(line) if line.strip() else {}
                if "commitInfo" in a and "timestamp" in a["commitInfo"]:
                    ns = int(a["commitInfo"]["timestamp"]) * 1_000_000
                    os.utime(log / name, ns=(ns, ns))
                    break


def call(scrub, f):
    try:
        return f()
    except Exception as e:  # deltalake raises its own classes and Rust panics as several types
        return error(e, scrub)


def history_upto(latest_history, version):
    return [h for h in latest_history if isinstance(h.get("version"), int) and h["version"] <= version]


def answer_version(path, table_dir, version, scrub, latest_history, apps):
    out = {"deltalake": DELTALAKE_VERSION, "engine": ENGINE, "table": table_dir.name, "version": version}
    out["actions"] = read_commit(table_dir, version)
    try:
        t = DeltaTable(path, version=version)
    except Exception as e:
        out["refusal"] = error(e, scrub)["error"]
        return out
    out["refusal"] = None
    out["loaded_version"] = t.version()
    out["schema"] = call(scrub, lambda: json.loads(t.schema().to_json()))
    out["protocol"] = call(scrub, lambda: protocol(t))
    out["metadata"] = call(scrub, lambda: metadata(t))
    out["history"] = history_upto(latest_history, version) if isinstance(latest_history, list) else latest_history
    out["add_actions"] = call(scrub, lambda: encode_table(pa.table(t.get_add_actions(flatten=False)), ["path"]))
    out["partitions"] = call(scrub, lambda: sorted((json_value(p) for p in t.partitions()),
                                                   key=lambda p: json.dumps(p, sort_keys=True)))
    out["count"] = call(scrub, lambda: json_value(t.count()))
    out["deletion_vectors"] = call(scrub, lambda: deletion_vectors(t, scrub))
    out["transactions"] = {a: call(scrub, lambda a=a: json_value(t.transaction_version(a))) for a in apps}
    out["read"] = call(scrub, lambda: encode_table(t.to_pyarrow_table(engine=ENGINE)))
    out["timestamp_lookup"] = call(scrub, lambda: timestamp_lookup(path, version, latest_history, scrub))
    return out


def protocol(t):
    p = t.protocol()
    return {
        "min_reader_version": p.min_reader_version,
        "min_writer_version": p.min_writer_version,
        "reader_features": None if p.reader_features is None else sorted(p.reader_features),
        "writer_features": None if p.writer_features is None else sorted(p.writer_features),
    }


def metadata(t):
    m = t.metadata()
    return json_value({
        "id": m.id,
        "name": m.name,
        "description": m.description,
        "partition_columns": list(m.partition_columns),
        "created_time": m.created_time,
        "configuration": dict(m.configuration),
    })


def deletion_vectors(t, scrub):
    rows = pa.table(t.deletion_vectors()).to_pylist()
    out = [{"path": scrub.relative(r["filepath"]),
            "deleted_rows": [i for i, keep in enumerate(r["selection_vector"]) if not keep],
            "selection_vector_length": len(r["selection_vector"])} for r in rows]
    return sorted(out, key=lambda r: r["path"])


def timestamp_lookup(path, version, latest_history, scrub):
    """The version deltalake resolves at, and 1 ms before, this version's commit timestamp."""
    if not isinstance(latest_history, list):
        return latest_history
    entry = next((h for h in latest_history if h.get("version") == version), None)
    if entry is None or "timestamp" not in entry:
        return None
    ms = int(entry.get("inCommitTimestamp", entry["timestamp"]))
    out = []
    for at in (ms - 1, ms):
        when = dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc) + dt.timedelta(milliseconds=at)
        t = DeltaTable(path)
        try:
            t.load_as_version(when)
            resolved = t.version()
        except Exception as e:
            resolved = error(e, scrub)
        out.append({"at": timestamp_text(at, "ms", True), "version": resolved})
    return out


def answer_table(table_dir):
    with tempfile.TemporaryDirectory() as scratch:
        path = os.path.join(scratch, table_dir.name)
        shutil.copytree(table_dir, path)
        set_commit_mtimes(path)
        scrub = Scrub(path)
        versions = log_versions(table_dir)
        try:
            latest_history = [json_value(h) for h in DeltaTable(path).history()]
        except Exception as e:
            latest_history = error(e, scrub)
        apps = app_ids(table_dir)
        answers = {v: answer_version(path, table_dir, v, scrub, latest_history, apps)
                   for v in range(0, versions[-1] + 1)}
    out_dir = ANSWERS / table_dir.name
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)
    for v, a in answers.items():
        text = json.dumps(a, sort_keys=True, indent=1, ensure_ascii=False, allow_nan=False) + "\n"
        if scratch in text or os.path.realpath(scratch) in text:
            sys.exit(f"{table_dir.name} {v}: an absolute path survived scrubbing")
        (out_dir / f"{v}.json").write_text(text, encoding="utf-8")
    return len(answers)


def main():
    if deltalake.__version__ != DELTALAKE_VERSION:
        sys.exit(f"deltalake {deltalake.__version__} found, {DELTALAKE_VERSION} required")
    wanted = set(sys.argv[1:])
    tables = sorted(p for p in TABLES.iterdir() if (p / "_delta_log").is_dir() and (not wanted or p.name in wanted))
    if not wanted and ANSWERS.exists():
        for stale in ANSWERS.iterdir():
            if stale.is_dir() and not (TABLES / stale.name / "_delta_log").is_dir():
                shutil.rmtree(stale)
    for p in tables:
        print(f"{p.name}: {answer_table(p)} versions")


if __name__ == "__main__":
    main()

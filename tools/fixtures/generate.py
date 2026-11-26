"""Write zulake's own fixture tables with deltalake 1.7.0.

    cd tools/oracle && uv run --frozen python ../fixtures/generate.py

Writes each table under tests/testthat/fixtures/tables/zl-<name>/, replacing
what is there. deltalake names data files with random UUIDs and stamps
commits with the clock, so a rerun gives different bytes: the tables are
generated once and committed, and tools/oracle/answers.py then answers for
the committed bytes. Where deltalake's writer cannot produce what a stage
needs (a multi-part checkpoint, a domainMetadata action, an unknown reader
feature), this script edits the log it wrote, and says so per table in
tests/testthat/fixtures/tables/PROVENANCE.md.

The zl-* tables are zulake's own (MIT). Two tables are delta-rs tables
(Apache-2.0) changed here, run after tools/fixtures/fetch-delta-rs.sh:
table-with-dv-small-inline and column_mapping_id_mode. They stay under the
delta-rs licence and carry the change notice in PROVENANCE.md.
"""

import datetime as dt
import decimal
import json
import os
import shutil
import sys
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq
from deltalake import CommitProperties, DeltaTable, Transaction, write_deltalake

ROOT = Path(__file__).resolve().parents[2]
TABLES = ROOT / "tests" / "testthat" / "fixtures" / "tables"
UTC = dt.timezone.utc


def fresh(name):
    path = TABLES / name
    if path.exists():
        shutil.rmtree(path)
    return str(path)


def log_dir(path):
    return Path(path) / "_delta_log"


def commit_name(version):
    return f"{version:020d}.json"


def append_commit(path, actions):
    """Write the next commit by hand, for actions deltalake cannot write."""
    logs = sorted(p.name for p in log_dir(path).glob("*.json") if p.name[:20].isdigit() and len(p.name) == 25)
    version = int(logs[-1][:20]) + 1
    lines = [json.dumps(a, separators=(",", ":")) for a in actions]
    (log_dir(path) / commit_name(version)).write_text("\n".join(lines) + "\n")
    return version


def commit_info(operation, **extra):
    now = int(dt.datetime.now(UTC).timestamp() * 1000)
    info = {"timestamp": now, "operation": operation, "operationParameters": {}, "clientVersion": "zulake-fixtures"}
    info.update(extra)
    return {"commitInfo": info}


def basic():
    """Unpartitioned; appends, a delete, an overwrite, app transactions."""
    p = fresh("zl-basic")
    sch = pa.schema([("id", pa.int64()), ("label", pa.string()), ("x", pa.float64())])
    write_deltalake(p, pa.table({"id": [1, 2, 3], "label": ["a", "b", "c"], "x": [0.5, 1.5, 2.5]}, schema=sch),
                    name="basic", description="zulake fixture: basic")
    write_deltalake(p, pa.table({"id": [4, 5], "label": ["d", None], "x": [3.5, None]}, schema=sch), mode="append",
                    commit_properties=CommitProperties(custom_metadata={"zulake.note": "first append"},
                                                       app_transactions=[Transaction("zulake-app", 1)]))
    DeltaTable(p).delete("id = 2")
    write_deltalake(p, pa.table({"id": [10, 11], "label": ["k", "l"], "x": [10.0, 11.0]}, schema=sch), mode="overwrite")
    write_deltalake(p, pa.table({"id": [12], "label": ["m"], "x": [12.0]}, schema=sch), mode="append",
                    commit_properties=CommitProperties(app_transactions=[Transaction("zulake-app", 2),
                                                                         Transaction("other-app", 7)]))


def types():
    """One row per edge value, in every type deltalake writes."""
    p = fresh("zl-types")
    big = [2**53 - 1, 2**53, 2**53 + 1, -(2**63), 2**63 - 1, None]
    n = len(big)
    t = pa.table({
        "i8": pa.array([-128, 127, 0, 1, -1, None], pa.int8()),
        "i16": pa.array([-32768, 32767, 0, 1, -1, None], pa.int16()),
        "i32": pa.array([-(2**31), 2**31 - 1, 0, 1, -1, None], pa.int32()),
        "i64": pa.array(big, pa.int64()),
        "f32": pa.array([1.5, -0.0, float("inf"), float("-inf"), 3.25, None], pa.float32()),
        "f64": pa.array([0.1, -0.0, float("inf"), float("-inf"), 1e308, None], pa.float64()),
        "dec": pa.array([decimal.Decimal("12345678.90"), decimal.Decimal("-0.01"), decimal.Decimal("0.00"),
                         decimal.Decimal("99999999.99"), decimal.Decimal("-99999999.99"), None], pa.decimal128(10, 2)),
        "dec38": pa.array([decimal.Decimal("12345678901234567890.123456789012345678"), decimal.Decimal("0"),
                           decimal.Decimal("-1.000000000000000001"), decimal.Decimal("1E-18"),
                           decimal.Decimal("-99999999999999999999.999999999999999999"), None],
                          pa.decimal128(38, 18)),
        "s": pa.array(["plain", "café", "日本語", "", "tab\there \"quoted\"", None], pa.string()),
        "b": pa.array([b"\x00\x01\xff", b"", b"abc", b"\xde\xad\xbe\xef", b"\x7f", None], pa.binary()),
        "flag": pa.array([True, False, True, False, True, None], pa.bool_()),
        "d": pa.array([dt.date(1970, 1, 1), dt.date(1969, 12, 31), dt.date(2000, 2, 29), dt.date(1, 1, 1),
                       dt.date(9999, 12, 31), None], pa.date32()),
        "ts": pa.array([dt.datetime(1970, 1, 1, tzinfo=UTC), dt.datetime(1969, 12, 31, 23, 59, 59, 999999, tzinfo=UTC),
                        dt.datetime(2024, 2, 29, 12, 30, 45, 123456, tzinfo=UTC), dt.datetime(1900, 1, 1, tzinfo=UTC),
                        dt.datetime(2262, 4, 11, tzinfo=UTC), None], pa.timestamp("us", tz="UTC")),
        "ntz": pa.array([dt.datetime(1970, 1, 1), dt.datetime(2024, 2, 29, 12, 30, 45, 123456),
                         dt.datetime(1969, 12, 31, 23, 59, 59, 999999), dt.datetime(2000, 1, 1),
                         dt.datetime(2100, 1, 1, 0, 0, 0, 1), None], pa.timestamp("us")),
        "st": pa.array([{"a": 1, "b": "x"}, {"a": None, "b": None}, None, {"a": 3, "b": "z"}, {"a": 4, "b": ""},
                        {"a": 5, "b": "w"}], pa.struct([("a", pa.int64()), ("b", pa.string())])),
        "li": pa.array([[1, 2], [], None, [None], [2**53 + 1], [0]], pa.list_(pa.int64())),
        "mp": pa.array([[("k", 1)], [], None, [("a", None), ("b", 2)], [("z", 0)], [("y", -1)]],
                       pa.map_(pa.string(), pa.int32())),
    })
    assert t.num_rows == n
    write_deltalake(p, t, name="types")


def partitioned():
    """Partitioned by string, integer and date; nulls and characters that need escaping."""
    p = fresh("zl-partitioned")
    sch = pa.schema([("value", pa.int64()), ("p_str", pa.string()), ("p_int", pa.int32()), ("p_date", pa.date32())])
    rows = {
        "value": [1, 2, 3, 4, 5, 6],
        "p_str": ["a", "a b", "x/y=z%", "café", None, "a"],
        "p_int": [1, 2, None, 3, 4, 1],
        "p_date": [dt.date(2024, 1, 1), dt.date(2024, 1, 2), dt.date(2024, 1, 3), None, dt.date(2024, 1, 5),
                   dt.date(2024, 1, 1)],
    }
    write_deltalake(p, pa.table(rows, schema=sch), partition_by=["p_str", "p_int", "p_date"])
    write_deltalake(p, pa.table({"value": [7], "p_str": ["a"], "p_int": [1], "p_date": [dt.date(2024, 1, 1)]},
                                schema=sch), mode="append", partition_by=["p_str", "p_int", "p_date"])
    DeltaTable(p).delete("p_int = 2")


def checkpointed():
    """Twelve commits, classic checkpoints at 5 and 10, removes before each."""
    p = fresh("zl-checkpoint")
    sch = pa.schema([("id", pa.int64()), ("v", pa.string())])
    write_deltalake(p, pa.table({"id": [0], "v": ["v0"]}, schema=sch))
    for i in range(1, 13):
        if i in (4, 9):
            DeltaTable(p).delete(f"id = {i - 2}")
        else:
            write_deltalake(p, pa.table({"id": [i], "v": [f"v{i}"]}, schema=sch), mode="append")
        if i in (5, 10):
            DeltaTable(p).create_checkpoint()


def checkpoint_no_last():
    """A classic checkpoint and no _last_checkpoint: readers must list the log."""
    p = fresh("zl-checkpoint-no-last")
    sch = pa.schema([("id", pa.int64())])
    write_deltalake(p, pa.table({"id": [0, 1]}, schema=sch))
    write_deltalake(p, pa.table({"id": [2]}, schema=sch), mode="append")
    write_deltalake(p, pa.table({"id": [3]}, schema=sch), mode="append")
    DeltaTable(p).create_checkpoint()
    write_deltalake(p, pa.table({"id": [4]}, schema=sch), mode="append")
    (log_dir(p) / "_last_checkpoint").unlink()


def multipart_checkpoint():
    """The classic checkpoint deltalake wrote, split into a three-part one."""
    p = fresh("zl-multipart-checkpoint")
    sch = pa.schema([("id", pa.int64())])
    write_deltalake(p, pa.table({"id": [0]}, schema=sch))
    for i in range(1, 4):
        write_deltalake(p, pa.table({"id": [i]}, schema=sch), mode="append")
    DeltaTable(p).delete("id = 1")
    DeltaTable(p).create_checkpoint()
    write_deltalake(p, pa.table({"id": [5]}, schema=sch), mode="append")
    version = 4
    single = log_dir(p) / f"{version:020d}.checkpoint.parquet"
    whole = pq.read_table(single)
    parts = 3
    bounds = [round(i * whole.num_rows / parts) for i in range(parts + 1)]
    for k in range(parts):
        name = f"{version:020d}.checkpoint.{k + 1:010d}.{parts:010d}.parquet"
        pq.write_table(whole.slice(bounds[k], bounds[k + 1] - bounds[k]), log_dir(p) / name)
    single.unlink()
    last = {"version": version, "size": whole.num_rows, "parts": parts}
    (log_dir(p) / "_last_checkpoint").write_text(json.dumps(last, separators=(",", ":")))


def compacted():
    """A log compaction file for commits 1 to 3."""
    p = fresh("zl-log-compaction")
    sch = pa.schema([("id", pa.int64())])
    write_deltalake(p, pa.table({"id": [0]}, schema=sch))
    for i in range(1, 5):
        write_deltalake(p, pa.table({"id": [i]}, schema=sch), mode="append")
    DeltaTable(p).delete("id = 2")
    DeltaTable(p).compact_logs(1, 3)


def domains():
    """domainMetadata added, changed and removed by hand-written commits."""
    p = fresh("zl-domains")
    sch = pa.schema([("id", pa.int64())])
    write_deltalake(p, pa.table({"id": [0]}, schema=sch))
    append_commit(p, [
        commit_info("SET DOMAIN"),
        {"protocol": {"minReaderVersion": 1, "minWriterVersion": 7, "writerFeatures": ["domainMetadata"]}},
        {"domainMetadata": {"domain": "zulake.test", "configuration": "{\"k\":1}", "removed": False}},
        {"domainMetadata": {"domain": "delta.zulake", "configuration": "{}", "removed": False}},
    ])
    append_commit(p, [
        commit_info("SET DOMAIN"),
        {"domainMetadata": {"domain": "zulake.test", "configuration": "{\"k\":2}", "removed": False}},
    ])
    append_commit(p, [
        commit_info("REMOVE DOMAIN"),
        {"domainMetadata": {"domain": "delta.zulake", "configuration": "{}", "removed": True}},
    ])
    write_deltalake(p, pa.table({"id": [1]}, schema=sch), mode="append")


def unknown_feature():
    """A reader feature no implementation knows: every reader must refuse it by name."""
    p = fresh("zl-unknown-reader-feature")
    sch = pa.schema([("id", pa.int64())])
    write_deltalake(p, pa.table({"id": [0, 1]}, schema=sch))
    append_commit(p, [
        commit_info("UPGRADE PROTOCOL"),
        {"protocol": {"minReaderVersion": 3, "minWriterVersion": 7,
                      "readerFeatures": ["zulakeUnknownFeature"], "writerFeatures": ["zulakeUnknownFeature"]}},
    ])


def catalog_managed():
    """The catalogManaged reader feature: zulake reads the filesystem only, and must refuse it by name."""
    p = fresh("zl-catalog-managed")
    sch = pa.schema([("id", pa.int64())])
    write_deltalake(p, pa.table({"id": [0, 1]}, schema=sch))
    # The protocol requires inCommitTimestamp alongside catalogManaged, and a
    # txnId in commitInfo, so the only thing a reader can refuse is the feature.
    first = [json.loads(line) for line in (log_dir(p) / commit_name(0)).read_text().splitlines() if line.strip()]
    meta = next(a for a in first if "metaData" in a)
    info = commit_info("UPGRADE PROTOCOL", txnId="5b4d6a8e-7f0c-4d1e-9a2b-3c4d5e6f7a8b")
    info["commitInfo"]["inCommitTimestamp"] = info["commitInfo"]["timestamp"]
    meta["metaData"]["configuration"].update({
        "delta.enableInCommitTimestamps": "true",
        "delta.inCommitTimestampEnablementVersion": "1",
        "delta.inCommitTimestampEnablementTimestamp": str(info["commitInfo"]["inCommitTimestamp"]),
    })
    append_commit(p, [
        info,
        {"protocol": {"minReaderVersion": 3, "minWriterVersion": 7,
                      "readerFeatures": ["catalogManaged"],
                      "writerFeatures": ["catalogManaged", "inCommitTimestamp"]}},
        meta,
    ])


def vacuum_protocol_check():
    """The vacuumProtocolCheck reader feature, which readers only acknowledge: zulake and deltalake must open it."""
    p = fresh("zl-vacuum-protocol-check")
    sch = pa.schema([("id", pa.int64())])
    write_deltalake(p, pa.table({"id": [0, 1]}, schema=sch))
    append_commit(p, [
        commit_info("UPGRADE PROTOCOL"),
        {"protocol": {"minReaderVersion": 3, "minWriterVersion": 7,
                      "readerFeatures": ["vacuumProtocolCheck"], "writerFeatures": ["vacuumProtocolCheck"]}},
    ])
    write_deltalake(p, pa.table({"id": [2]}, schema=sch), mode="append")


Z85 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#"


def z85(data):
    """ZeroMQ RFC 32 Z85, the encoding of inline deletion vectors."""
    assert len(data) % 4 == 0
    out = []
    for i in range(0, len(data), 4):
        value = int.from_bytes(data[i:i + 4], "big")
        chars = []
        for _ in range(5):
            chars.append(Z85[value % 85])
            value //= 85
        out.append("".join(reversed(chars)))
    return "".join(out)


def derived(source, name):
    src = TABLES / source
    if not src.exists():
        sys.exit(f"{source} missing: run tools/fixtures/fetch-delta-rs.sh first")
    p = fresh(name)
    shutil.copytree(src, p)
    return p


def rewrite_commit(path, version, edit):
    f = log_dir(path) / commit_name(version)
    actions = [json.loads(line) for line in f.read_text().splitlines() if line.strip()]
    f.write_text("\n".join(json.dumps(edit(a), separators=(",", ":")) for a in actions) + "\n")


def inline_dv():
    """delta-rs table-with-dv-small with its deletion vector moved inline (storageType "i")."""
    p = derived("table-with-dv-small", "table-with-dv-small-inline")
    (binf,) = Path(p).glob("deletion_vector_*.bin")
    raw = binf.read_bytes()
    size = int.from_bytes(raw[1:5], "big")
    serialized = raw[5:5 + size]
    binf.unlink()

    def edit(action):
        if "add" in action:
            old = action["add"]["deletionVector"]
            action["add"]["deletionVector"] = {"storageType": "i", "pathOrInlineDv": z85(serialized),
                                               "sizeInBytes": size, "cardinality": old["cardinality"]}
        return action

    rewrite_commit(p, 1, edit)


def column_mapping_id():
    """delta-rs column_mapping with delta.columnMapping.mode set to "id"; its Parquet carries field IDs."""
    p = derived("column_mapping", "column_mapping_id_mode")

    def edit(action):
        if "metaData" in action:
            action["metaData"]["configuration"]["delta.columnMapping.mode"] = "id"
        return action

    for version in (0, 2):
        rewrite_commit(p, version, edit)


def main():
    if len(sys.argv) > 1:
        wanted = set(sys.argv[1:])
    else:
        wanted = None
    for fn in (basic, types, partitioned, checkpointed, checkpoint_no_last, multipart_checkpoint, compacted, domains,
               unknown_feature, catalog_managed, vacuum_protocol_check, inline_dv, column_mapping_id):
        if wanted is None or fn.__name__ in wanted:
            fn()
            print("wrote", fn.__name__)


if __name__ == "__main__":
    main()

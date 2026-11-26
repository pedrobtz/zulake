# The oracle: deltalake 1.7.0's answers

`answers.py` asks the Python `deltalake` package, version 1.7.0, every
question zulake answers, for every fixture table at every version, and
writes the answers as JSON under `tests/testthat/fixtures/answers/`. The R
tests compare zulake with those files through `expect_oracle()` in
`tests/testthat/helper-oracle.R`, so they need no Python.

```sh
cd tools/oracle
uv run --frozen python answers.py            # every table
uv run --frozen python answers.py zl-basic   # one table
```

The environment is pinned: `.python-version` (CPython 3.12.11),
`pyproject.toml` and `uv.lock` (`deltalake` 1.7.0, `pyarrow` 22.0.0), run
with `uv` 0.7.11. `.github/workflows/oracle.yaml` runs the same commands on
every pull request that touches the harness or the fixtures, and on dispatch,
and fails if the regenerated files differ from the committed ones.

## Files

One file per table and version: `answers/<table>/<version>.json`, for every
version from 0 to the last commit or checkpoint in the table's `_delta_log/`.
Keys are sorted, rows are in a fixed order, the scratch copy's location is
written `<table>`, and nothing about the run (time, host, paths) is recorded.

The harness reads each table from a scratch copy whose commit files have
their modification time set to their own `commitInfo.timestamp`, because
the protocol resolves a timestamp to a version by modification time when
`inCommitTimestamp` is off, and git keeps no modification times. A test of
timestamp lookup does the same to its copy.

## Fields

| Field | What | From |
| --- | --- | --- |
| `deltalake`, `engine` | `"1.7.0"`, `"datafusion"` | the harness |
| `table`, `version` | the table's directory name and the version asked for | the harness |
| `actions` | the actions of commit `<version>.json`, one object per line, in file order; `null` when the commit file is gone | Python's `json`, not `deltalake`: the oracle's own parse |
| `refusal` | `null`, or `{class, message}` when `DeltaTable(path, version=)` raised; then no field below is present | `deltalake` |
| `loaded_version` | `DeltaTable.version()` | `deltalake` |
| `schema` | `schema().to_json()`, parsed | `deltalake` |
| `protocol` | `min_reader_version`, `min_writer_version`, `reader_features`, `writer_features` (sorted, or `null`) | `protocol()` |
| `metadata` | `id`, `name`, `description`, `partition_columns`, `created_time`, `configuration` | `metadata()` |
| `history` | the commits up to `<version>`, newest first | `history()` of the latest snapshot (see below) |
| `add_actions` | the live files, a table, rows sorted by `path` | `get_add_actions(flatten=False)` |
| `partitions` | one object per live partition, sorted | `partitions()` |
| `count` | rows | `count()` |
| `deletion_vectors` | per file with a vector: `path` (relative), `deleted_rows` (0-based row indexes) and `selection_vector_length` | `deletion_vectors()` |
| `transactions` | `{appId: version}` for every `appId` the log mentions | `transaction_version()` |
| `read` | the full table, a table | `to_pyarrow_table(engine="datafusion")` |
| `timestamp_lookup` | `[{at, version}]` for 1 ms before and at this version's commit timestamp (`inCommitTimestamp` when present) | `load_as_version(datetime)` |

A field `deltalake` could not answer holds `{"error": {"class", "message"}}`
instead of its value: a refusal by name (an unknown reader feature) is
recorded, not skipped. A table zulake must refuse and `deltalake` reads
(`column_mapping_id_mode`) has ordinary answers; the R test asserts the
refusal itself.

`history` comes from the latest snapshot, filtered to versions up to
`<version>`: on a snapshot loaded at an older version, `deltalake` 1.7.0's
`history()` reports negative version numbers (seen 2026-11-26 on
`simple_table_with_checkpoint` at version 0, design §8).

## Encoding

Two kinds of field, two encodings, both plain JSON that `zujson` parses.

**Log JSON** (`actions`, `schema`, `metadata`, `history`, `partitions`,
`count`, `transactions`): the values as parsed, except that an integer
outside ±(2^53 − 1) is written as a string of its decimal digits, so no
reader rounds it. Strings in the log (statistics, `schemaString`,
`partitionValues`) stay the strings the log holds.

**Tables** (`add_actions`, `read`): an object

```json
{"schema": [{"name": "id", "type": "int64", "nullable": true}],
 "num_rows": 3,
 "columns": {"id": ["1", "2", "3"]}}
```

`schema` gives the Arrow type of each column in order (string, binary and
list views and their large variants are named as the plain type);
`columns` maps each name to its values, one per row, encoded by type:

| Arrow type | JSON |
| --- | --- |
| `int8`, `int16`, `int32`, `uint8`, `uint16` | number |
| `int64`, `uint32`, `uint64` | string of decimal digits |
| `float`, `double` | number (shortest exact form, `-0.0` kept); `"NaN"`, `"Infinity"`, `"-Infinity"` |
| `decimal128(p, s)` | string, plain notation with all `s` decimals (`"0.00"`) |
| `bool` | `true`/`false` |
| `string` | string |
| `binary` | lowercase hex |
| `date32` | `"YYYY-MM-DD"`, proleptic Gregorian, years 1 to 9999 |
| `timestamp[unit, tz=UTC]` | `"YYYY-MM-DDTHH:MM:SS.ffffffZ"`, with as many fraction digits as the unit has (3, 6, 9); computed from the integer, so no range limit |
| `timestamp[unit]` (no zone, `timestamp_ntz`) | the same without `Z` |
| `struct` | object of its fields |
| `list` | array |
| `map` | array of `[key, value]` pairs |
| any type, null | `null` |

Rows of `read` are sorted by the JSON of the whole row and rows of
`add_actions` by `path`, so the order is deltalake's answer's, not the
order of a scan. `expect_oracle()` compares rows in any order.

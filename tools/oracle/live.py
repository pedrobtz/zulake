"""deltalake 1.7.0's answers for one table on a live Azure account.

    cd tools/oracle && uv run --frozen python live.py <out-dir>

With ZULAKE_AZURE_URI (the table, abfss:// or https://) and
ZULAKE_AZURE_TOKEN (a token for https://storage.azure.com) set, writes
<out-dir>/live/<version>.json for the table's latest version, in
answers.py's format, for test-azure-live.R. There is no local copy of the
table, so `actions` is null and `transactions` and `timestamp_lookup` are
not asked. .github/workflows/azure-live.yaml runs it on dispatch.
"""

import json
import os
import sys
from pathlib import Path

import answers as A


def main():
    if A.deltalake.__version__ != A.DELTALAKE_VERSION:
        sys.exit(f"deltalake {A.deltalake.__version__} found, {A.DELTALAKE_VERSION} required")
    out = Path(sys.argv[1]) / "live"
    uri = os.environ["ZULAKE_AZURE_URI"]
    A.STORAGE_OPTIONS = {"bearer_token": os.environ["ZULAKE_AZURE_TOKEN"]}
    A.timestamp_lookup = lambda *args: None
    A.read_commit = lambda *args: None
    scrub = A.Scrub(uri)
    t = A.open_table(uri)
    version = t.version()
    latest_history = [A.json_value(h) for h in t.history()]
    a = A.answer_version(uri, Path("live"), version, scrub, latest_history, [])
    out.mkdir(parents=True, exist_ok=True)
    text = json.dumps(a, sort_keys=True, indent=1, ensure_ascii=False, allow_nan=False) + "\n"
    (out / f"{version}.json").write_text(text, encoding="utf-8")
    print(f"live: version {version}")


if __name__ == "__main__":
    main()

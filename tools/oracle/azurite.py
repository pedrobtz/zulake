"""deltalake 1.7.0's answers for the fixture tables uploaded to Azurite.

    cd tools/oracle && uv run --frozen python azurite.py <out-dir>

With Azurite up and the fixtures uploaded (tools/azurite/README.md), and
ZULAKE_AZURITE_ENDPOINT (Azurite's blob endpoint with the account) and
ZULAKE_AZURITE_TOKEN (the test token of tests/testthat/helper-azure.R) set,
writes <out-dir>/<table>/<version>.json for every table of the container
"fixtures" and every version, in answers.py's format, read through the Blob
API with the bearer token, as test-azure-emulator.R reads them. The fields
are answers.py's, except `timestamp_lookup`, which is null: Azurite gives
each blob its upload time, so commit times are not the fixtures'.

Azurite's certificate is self-signed for the run; deltalake is told to
accept it (allow_invalid_certificates), zulake is given its CA.
"""

import json
import os
import sys
from pathlib import Path

import answers as A


def main():
    if A.deltalake.__version__ != A.DELTALAKE_VERSION:
        sys.exit(f"deltalake {A.deltalake.__version__} found, {A.DELTALAKE_VERSION} required")
    out = Path(sys.argv[1])
    A.STORAGE_OPTIONS = {
        "account_name": "devstoreaccount1",
        "azure_storage_endpoint": os.environ["ZULAKE_AZURITE_ENDPOINT"],
        "bearer_token": os.environ["ZULAKE_AZURITE_TOKEN"],
        "allow_invalid_certificates": "true",
    }
    A.timestamp_lookup = lambda *args: None
    tables = sorted(p for p in A.TABLES.iterdir() if (p / "_delta_log").is_dir())
    for table_dir in tables:
        uri = f"az://fixtures/{table_dir.name}"
        scrub = A.Scrub(uri)
        try:
            latest_history = [A.json_value(h) for h in A.open_table(uri).history()]
        except Exception as e:
            latest_history = A.error(e, scrub)
        apps = A.app_ids(table_dir)
        versions = A.log_versions(table_dir)
        out_dir = out / table_dir.name
        out_dir.mkdir(parents=True, exist_ok=True)
        for v in range(0, versions[-1] + 1):
            a = A.answer_version(uri, table_dir, v, scrub, latest_history, apps)
            text = json.dumps(a, sort_keys=True, indent=1, ensure_ascii=False, allow_nan=False) + "\n"
            (out_dir / f"{v}.json").write_text(text, encoding="utf-8")
        print(f"{table_dir.name}: {versions[-1] + 1} versions")


if __name__ == "__main__":
    main()

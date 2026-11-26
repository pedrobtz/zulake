"""Pack the fixture tables and hostile logs into one tar the package ships.

    cd tools/oracle && uv run --frozen python ../fixtures/pack.py

Delta tables have paths longer than the 100 bytes R CMD check accepts in a
package tarball ("checking for portable file names") and hidden files (the
.crc sidecars Spark writes), so the unpacked trees under
tests/testthat/fixtures/tables/ and hostile/ are left out of the build
(.Rbuildignore) and this tar is shipped instead. tests/testthat/helper-oracle.R
unpacks it once per session.

The tar is deterministic: entries sorted, every mtime, owner and mode fixed,
GNU long-name headers, no compression (R CMD build compresses the package).
oracle.yaml repacks and fails on any diff, so the tar never drifts from the
trees.
"""

import io
import os
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests" / "testthat" / "fixtures"
OUT = FIXTURES / "delta-fixtures.tar"
MEMBERS = ("tables", "hostile")
MTIME = 1767225600  # 2026-01-01T00:00:00Z


def entries():
    for top in MEMBERS:
        base = FIXTURES / top
        yield top, base
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames.sort()
            rel = Path(dirpath).relative_to(FIXTURES)
            for d in dirnames:
                yield (rel / d).as_posix(), Path(dirpath) / d
            for f in sorted(filenames):
                yield (rel / f).as_posix(), Path(dirpath) / f


def main():
    items = sorted(entries(), key=lambda e: e[0])
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tar:
        for name, path in items:
            info = tarfile.TarInfo(name)
            info.mtime = MTIME
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            if path.is_dir():
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tar.addfile(info)
            else:
                data = path.read_bytes()
                info.size = len(data)
                info.mode = 0o644
                tar.addfile(info, io.BytesIO(data))
    OUT.write_bytes(buf.getvalue())
    print(f"{OUT.relative_to(ROOT)}: {len(items)} entries, {OUT.stat().st_size} bytes")


if __name__ == "__main__":
    main()

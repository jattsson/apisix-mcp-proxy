"""Verify deterministic packaging and installation from the release archive."""
import hashlib
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
archive = root / ".test/release/apisix-mcp-proxy-0.1.0.tar.gz"
subprocess.run([sys.executable, str(root / "scripts/package.py")], check=True)
first = archive.read_bytes()
subprocess.run([sys.executable, str(root / "scripts/package.py")], check=True)
assert archive.read_bytes() == first, "Build is not reproducible"
assert (archive.parent / "SHA256SUMS").read_text().split()[0] == hashlib.sha256(first).hexdigest()
with tempfile.TemporaryDirectory() as directory:
    target = Path(directory)
    with tarfile.open(archive) as tar:
        names = tar.getnames()
        assert all(n.startswith("apisix-mcp-proxy-0.1.0/") for n in names)
        assert not any(part in n.split("/") for n in names
                       for part in (".git", ".test", "fixtures", "tests"))
        tar.extractall(target, filter="data")
    source = target / "apisix-mcp-proxy-0.1.0"
    destination = target / "installed"
    subprocess.run(["bash", str(source / "scripts/install.sh"), str(destination)], check=True)
    lua = list((source / "apisix").rglob("*.lua"))
    assert len(lua) == 9
    for path in lua:
        assert path.read_bytes() == (destination / path.relative_to(source)).read_bytes()
    for name in ("LICENSE", "NOTICE", "VERSION"):
        assert (source / name).read_bytes() == (destination / name).read_bytes()
    assert len((source / "REVISION").read_text().strip()) == 40
print("Reproducible archive, checksum, allowlist and installed files verified")
